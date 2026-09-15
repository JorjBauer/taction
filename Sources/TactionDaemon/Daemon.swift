import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import TactionKit
import TactionHID

/// Wires the panel, the display, the pipeline, and the event poster together on the main run loop.
public final class Daemon {
    public private(set) var config: TactionConfig
    private let configURL: URL
    private let foreground: Bool

    private let watcher = PanelWatcher()
    private var device: PanelDevice?
    private var display: ResolvedDisplay?
    private var pipeline: Pipeline
    private let poster = EventPoster()
    public private(set) var status: Status
    /// Called on the main thread whenever the status file is rewritten.
    public var onStatusChange: ((Status) -> Void)?

    private var tickTimer: Timer?
    private var staleTimer: Timer?
    private var displayRetryTimer: Timer?
    private var lastReportTime: Double?

    /// Raw report recording for offline replay (`--record FILE`).
    private let recordURL: URL?
    private var recorded: [CapturedReport] = []
    private var recordFlushTimer: Timer?

    public init(config: TactionConfig, configURL: URL, foreground: Bool, recordURL: URL? = nil) {
        self.config = config
        self.configURL = configURL
        self.foreground = foreground
        self.recordURL = recordURL
        // Until a display is bound, map onto an empty rect at the origin; posting stays disabled anyway.
        pipeline = Pipeline(mapper: DisplayMapper(geometry: DisplayGeometry(frame: .zero), calibration: config.calibration),
                            gestures: config.gestures)
        status = Status(pid: getpid(), startedAt: Date(), updatedAt: Date(), configPath: configURL.path)
        Log.level = config.logLevel
        Log.mirrorToStderr = foreground
    }

    // MARK: Lifecycle

    public func start() {
        Log.info("daemon", "tactiond starting, config \(configURL.path), seize=\(config.seize)")
        checkPermissions(prompt: foreground)
        bindDisplay()
        registerDisplayCallback()
        registerWorkspaceNotifications()
        installSignalHandlers()

        watcher.onMatch = { [weak self] d in self?.deviceMatched(d) }
        watcher.onRemove = { [weak self] d in self?.deviceRemoved(d) }
        watcher.start(runLoop: CFRunLoopGetMain())
        Log.info("hid", "watching for vid 0x0eef pid 0xc000")
        logHotkeys()
        if let url = recordURL {
            Log.info("daemon", "recording raw reports to \(url.path)")
            recordFlushTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.flushRecording() }
        }
        writeStatus()
    }

    private func flushRecording() {
        guard let url = recordURL, !recorded.isEmpty else { return }
        do {
            let data = FixtureFile.encode(recorded)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url)
            }
            Log.debug("daemon", "flushed \(recorded.count) recorded reports")
            recorded.removeAll()
        } catch {
            Log.error("daemon", "recording write failed: \(error)")
        }
    }

    private func logHotkeys() {
        for action in [SystemAction.previousSpace, .nextSpace, .missionControl, .appExpose] {
            let d = poster.hotkeys.describe(action)
            if d.hasPrefix("UNAVAILABLE") { Log.error("post", "\(action): \(d)") } else { Log.info("post", "\(action): \(d)") }
        }
    }

    public func shutdown() {
        Log.info("daemon", "shutting down")
        releaseEverything()
        device?.close()
        device = nil
        watcher.stop()
        flushRecording()
        writeStatus()
    }

    // MARK: Permissions

    private func checkPermissions(prompt: Bool) {
        // Always ask for Accessibility: the prompt is harmless and, when launched by launchd, it is
        // the only way the user learns the grant is missing. Without it every CGEvent is dropped.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        status.accessibility = AXIsProcessTrustedWithOptions(options)
        if !status.accessibility {
            Log.error("daemon", "Accessibility not granted; CGEvents will be dropped. Grant it in System Settings > Privacy & Security > Accessibility.")
        }
        var im = InputMonitoring.status()
        if im != .granted { im = InputMonitoring.request() }
        status.inputMonitoring = im.rawValue
        if im != .granted {
            // macOS does not always show the prompt for a background process; the user may need the + button.
            Log.error("daemon", "Input Monitoring is \(im.rawValue); no reports will arrive until it is granted (System Settings > Privacy & Security > Input Monitoring, add \(CommandLine.arguments[0])).")
        }
        _ = prompt
        if !status.accessibility || im != .granted { startPermissionPolling() }
    }

    private var permissionTimer: Timer?

    /// Grants can arrive while running (the user flips a switch in System Settings). Poll until
    /// both are present; a device opened before Input Monitoring was granted delivers nothing, so
    /// reopen it once the grant appears.
    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let ax = AXIsProcessTrusted()
            let im = InputMonitoring.status()
            var changed = false
            if ax != self.status.accessibility {
                self.status.accessibility = ax
                changed = true
                Log.info("daemon", "Accessibility is now \(ax ? "granted" : "not granted")")
            }
            if im.rawValue != self.status.inputMonitoring {
                self.status.inputMonitoring = im.rawValue
                changed = true
                Log.info("daemon", "Input Monitoring is now \(im.rawValue)")
                if im == .granted, let d = self.device {
                    Log.info("hid", "reopening the panel now that Input Monitoring is granted")
                    self.releaseEverything()
                    d.close()
                    self.openAndStart(d)
                }
            }
            if changed { self.writeStatus() }
            if ax && im == .granted {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    // MARK: Display

    private var displayBindAttempted = false

    private func bindDisplay() {
        let resolved = DisplayBinder.resolve(config.display)
        // The first attempt must log and arm the retry even when nothing matched (nil == nil).
        let changed = resolved != display || !displayBindAttempted
        displayBindAttempted = true
        if changed {
            display = resolved
            if let r = resolved {
                Log.info("display", "bound to \(r.summary)")
                pipeline.mapper = DisplayMapper(geometry: r.geometry, calibration: config.calibration)
                status.display = r.summary
                status.displayBound = true
                displayRetryTimer?.invalidate()
                displayRetryTimer = nil
            } else {
                Log.error("display", "no display matches \(config.display); online: \(DisplayBinder.describeAll()). Touch is tracked but nothing is posted.")
                status.display = DisplayBinder.describeAll()
                status.displayBound = false
                // Displays can appear a few seconds after the panel's USB side; keep looking.
                if displayRetryTimer == nil {
                    displayRetryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.bindDisplay() }
                }
            }
            writeStatus()
        }
    }

    private func registerDisplayCallback() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // The callback fires before and after each change. Bounds are only final in the
            // "after" call, which is the one without the begin flag.
            guard let context = context, !flags.contains(.beginConfigurationFlag) else { return }
            let me = Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.bindDisplay() }
        }, context)
    }

    // MARK: Sleep and wake

    private func registerWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Log.info("daemon", "system will sleep")
            self?.releaseEverything()
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.info("daemon", "system woke")
            guard let self = self else { return }
            self.bindDisplay()
            // The firmware forgets its mode across some sleeps without re-enumerating.
            if let d = self.device, d.isOpen {
                do { try d.setMultiTouchMode() } catch { Log.error("hid", "mode resend after wake: \(error)") }
            }
        }
    }

    // MARK: Signals

    private var signalSources: [DispatchSourceSignal] = []

    private func installSignalHandlers() {
        for (sig, name) in [(SIGHUP, "SIGHUP"), (SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                guard let self = self else { return }
                if sig == SIGHUP {
                    self.reloadConfig()
                } else {
                    Log.info("daemon", "\(name) received")
                    self.shutdown()
                    exit(0)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    public func reloadConfig() {
        do {
            let fresh = try TactionConfig.load(from: configURL)
            let reopen = fresh.seize != config.seize
            config = fresh
            Log.level = fresh.logLevel
            pipeline.engine.config = fresh.gestures
            pipeline.mapper.calibration = fresh.calibration
            poster.hotkeys.reload()
            Log.info("daemon", "config reloaded")
            logHotkeys()
            bindDisplay()
            if reopen, let d = device {
                Log.info("hid", "seize setting changed; reopening")
                releaseEverything()
                d.close()
                openAndStart(d)
            }
            writeStatus()
        } catch {
            Log.error("daemon", "config reload failed, keeping previous: \(error)")
            status.lastError = "config reload: \(error)"
            writeStatus()
        }
    }

    // MARK: Device

    private func deviceMatched(_ d: PanelDevice) {
        Log.info("hid", "panel attached: \(d.summary)")
        // If IOHIDFamily exposes several devices for the panel, only drive the touch screen collection.
        if let page = d.primaryUsagePage, let usage = d.primaryUsage, !(page == 0x0D && usage == 0x04) {
            Log.info("hid", "ignoring non-digitizer collection (usage \(page)/\(usage))")
            return
        }
        if device != nil {
            Log.info("hid", "a panel is already open; ignoring the additional device")
            return
        }
        // USB 0EEF:C000 is EETI's shared product ID: other eGalax controllers use it with different
        // report layouts. The parser's offsets are only valid for the descriptor we know, so refuse
        // anything else rather than post garbage. The probe prints the diff for a support report.
        if let live = d.reportDescriptor, live != ReferenceDescriptor.bytes {
            let firstDiff = zip(live, ReferenceDescriptor.bytes).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(live.count, ReferenceDescriptor.bytes.count)
            let message = "unsupported panel: \(d.product ?? "unknown") has a \(live.count)-byte HID descriptor that differs from the known \(ReferenceDescriptor.bytes.count)-byte one at offset \(firstDiff). Not driving it. Run 'taction-probe descriptor' and open an issue with the output."
            Log.error("hid", message)
            status.devicePresent = true
            status.deviceOpen = false
            status.deviceSummary = d.summary
            status.lastError = message
            writeStatus()
            return
        }
        device = d
        status.devicePresent = true
        status.deviceSummary = d.summary
        status.lastError = nil
        openAndStart(d)
        writeStatus()
    }

    private func openAndStart(_ d: PanelDevice) {
        do {
            try d.open(seize: config.seize)
            Log.info("hid", "opened\(config.seize ? " with seize" : "")")
        } catch {
            Log.error("hid", "\(error)")
            status.lastError = "\(error)"
            if config.seize {
                // Fall back to a shared open so at least the reports flow; the log says why.
                do {
                    try d.open(seize: false)
                    Log.error("hid", "opened WITHOUT seize as a fallback; the system may also move the pointer")
                } catch {
                    Log.error("hid", "fallback open failed too: \(error)")
                    status.deviceOpen = false
                    writeStatus()
                    return
                }
            } else {
                status.deviceOpen = false
                writeStatus()
                return
            }
        }
        status.deviceOpen = true
        status.seized = d.isSeized
        status.lastError = nil

        do {
            try d.setMultiTouchMode()
            Log.info("hid", "device mode set to multi-input")
        } catch {
            Log.error("hid", "device mode write failed: \(error)")
            status.lastError = "\(error)"
        }

        d.startReports { [weak self] bytes, t in self?.handleReport(bytes, at: t) }
    }

    private func deviceRemoved(_ d: PanelDevice) {
        guard d === device else { return }
        Log.info("hid", "panel removed")
        releaseEverything()
        device = nil
        status.devicePresent = false
        status.deviceOpen = false
        status.seized = false
        status.deviceSummary = nil
        writeStatus()
    }

    // MARK: Reports

    private func handleReport(_ bytes: [UInt8], at t: Double) {
        lastReportTime = t
        if recordURL != nil { recorded.append(CapturedReport(nanoseconds: UInt64(t * 1_000_000_000), bytes: bytes)) }
        let result = pipeline.ingest(report: bytes, at: t)
        if let frame = result.frame {
            Log.debug("hid", "frame \(Formatting.describe(frame)) \(result.touches.map(Formatting.describe).joined(separator: ", "))")
        } else {
            Log.debug("hid", "unparsable report id=\(bytes.first ?? 0) len=\(bytes.count)")
        }
        emit(result.actions, now: t)
        updateTimers()
        if pipeline.framesSeen % 500 == 1 { writeStatus() }
    }

    private var postingEnabled: Bool {
        display != nil && !FileManager.default.fileExists(atPath: TactionConfig.calibrationLockURL.path)
    }

    private func emit(_ actions: [OutputAction], now: Double) {
        guard !actions.isEmpty else { return }
        poster.suppressed = !postingEnabled
        poster.post(actions, now: now)
    }

    private func updateTimers() {
        if pipeline.engine.needsTick {
            if tickTimer == nil {
                tickTimer = Timer.scheduledTimer(withTimeInterval: 0.010, repeats: true) { [weak self] _ in self?.tick() }
            }
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }

        staleTimer?.invalidate()
        staleTimer = nil
        if pipeline.tracker.activeCount > 0 {
            let seen = lastReportTime
            staleTimer = Timer.scheduledTimer(withTimeInterval: config.staleContactTimeoutMs / 1000, repeats: false) { [weak self] _ in
                guard let self = self, self.lastReportTime == seen else { return }
                Log.info("gesture", "no reports for \(Int(self.config.staleContactTimeoutMs)) ms with fingers down; releasing")
                self.releaseEverything()
            }
        }
    }

    private func tick() {
        let now = HostClock.nowSeconds()
        emit(pipeline.tick(now: now), now: now)
        if !pipeline.engine.needsTick {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func releaseEverything() {
        let now = HostClock.nowSeconds()
        emit(pipeline.releaseAll(at: now), now: now)
        poster.releaseLeftIfDown(at: nil)
        tickTimer?.invalidate()
        tickTimer = nil
        staleTimer?.invalidate()
        staleTimer = nil
    }

    // MARK: Status

    private func writeStatus() {
        status.updatedAt = Date()
        status.posting = postingEnabled && status.accessibility
        status.framesSeen = pipeline.framesSeen
        status.parseErrors = pipeline.parseErrors
        if let t = lastReportTime {
            status.lastReportAt = Date().addingTimeInterval(t - HostClock.nowSeconds())
        }
        status.write()
        onStatusChange?(status)
    }
}
