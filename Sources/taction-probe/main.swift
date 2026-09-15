import Foundation
import CoreGraphics
import TactionKit
import TactionHID

// taction-probe: diagnostics for the eGalax EXC3200 in the ASUS ZenScreen Touch MB16AMT.
// See taction/02-project-probe.md for what each subcommand is for.

let usage = """
usage: taction-probe <command> [options]

commands:
  list                         enumerate matching IOHIDDevices and print their properties
  descriptor                   hex dump the HID report descriptor and diff it against the expected one
  features [--no-write]        read feature 0x0E and 5, write device mode 2, read 5 back
  capture [--seize] [--seconds N] [--out FILE] [--no-mode] [--quiet]
                               stream input reports, decoded, optionally to a fixture file
  watch-cursor [--seconds N]   report pointer movement without opening the device
  permissions                  print Input Monitoring status; --request shows the prompt

options apply after the command. Exit codes: 0 ok, 1 usage, 2 no device, 3 open failed, 4 report failed.
"""

struct Options {
    var seize = false
    var seconds: Double = 30
    var out: String?
    var writeMode = true
    var quiet = false
    var request = false
    var noWrite = false
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--seize": o.seize = true
        case "--seconds": i += 1; o.seconds = Double(args[safe: i] ?? "") ?? 30
        case "--out": i += 1; o.out = args[safe: i]
        case "--no-mode": o.writeMode = false
        case "--quiet": o.quiet = true
        case "--request": o.request = true
        case "--no-write": o.noWrite = true
        default:
            fputs("unknown option \(args[i])\n\(usage)", stderr)
            exit(1)
        }
        i += 1
    }
    return o
}

extension Array where Element == String {
    subscript(safe i: Int) -> String? { i < count ? self[i] : nil }
}

func fail(_ code: Int32, _ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(code)
}

func firstPanel(_ watcher: PanelWatcher) -> PanelDevice {
    let devices = watcher.currentDevices()
    guard !devices.isEmpty else { fail(2, "no device with vid 0x0eef pid 0xc000 is attached (is the panel connected, and is another touch driver claiming it?)") }
    // Prefer the digitizer collection if IOHIDFamily split the descriptor into several devices.
    if let touch = devices.first(where: { $0.primaryUsagePage == 0x0D && $0.primaryUsage == 0x04 }) { return touch }
    return devices[0]
}

// MARK: commands

func cmdList() {
    let watcher = PanelWatcher()
    let devices = watcher.currentDevices()
    if devices.isEmpty {
        print("no matching devices")
        exit(2)
    }
    print("\(devices.count) matching device(s):")
    for d in devices {
        print("  \(d.summary)")
        print("    manufacturer=\(d.manufacturer ?? "?") serial=\(d.serialNumber ?? "none") version=\(d.versionNumber.map { String(format: "0x%04x", $0) } ?? "?") transport=\(d.transport ?? "?")")
        print("    maxFeature=\(d.maxFeatureReportSize ?? -1) descriptorBytes=\(d.reportDescriptor?.count ?? 0)")
        print("    \(d.registryPath ?? "(no registry path)")")
    }
    print("Input Monitoring: \(InputMonitoring.status().rawValue)")
}

func cmdDescriptor() {
    let d = firstPanel(PanelWatcher())
    guard let desc = d.reportDescriptor else { fail(4, "device has no kIOHIDReportDescriptorKey") }
    print("\(desc.count) bytes")
    for row in stride(from: 0, to: desc.count, by: 16) {
        let slice = Array(desc[row..<min(row + 16, desc.count)])
        print(String(format: "%04x  ", row) + Formatting.hex(slice))
    }
    if desc == ReferenceDescriptor.bytes {
        print("matches the reference descriptor (496 bytes). Parser offsets are valid.")
    } else {
        print("DIFFERS from the recorded descriptor (\(ReferenceDescriptor.bytes.count) bytes). See docs/PANEL-PROTOCOL.md; Taction will not drive this panel.")
        let n = min(desc.count, ReferenceDescriptor.bytes.count)
        if let first = (0..<n).first(where: { desc[$0] != ReferenceDescriptor.bytes[$0] }) {
            print(String(format: "first difference at offset 0x%04x: got %02x expected %02x", first, desc[first], ReferenceDescriptor.bytes[first]))
        }
    }
}

func cmdFeatures(_ o: Options) {
    let d = firstPanel(PanelWatcher())
    print(d.summary)
    do { try d.open(seize: false) } catch { fail(3, "\(error)") }
    defer { d.close() }

    if let max = try? d.getFeature(reportID: ContactCountMaximum.reportID, maxLength: 8) {
        print("feature 0x0E (contact count maximum, device index): \(Formatting.hex(max))")
    } else {
        print("feature 0x0E: read failed")
    }
    do {
        let mode = try d.getFeature(reportID: DeviceMode.reportID, maxLength: 8)
        print("feature 5 before write (device mode, device identifier): \(Formatting.hex(mode))  mode=\(mode.first.map(String.init) ?? "?") (0 mouse, 1 single, 2 multi)")
    } catch {
        print("feature 5 read before write failed: \(error)")
    }
    if o.noWrite { return }
    do {
        try d.setMultiTouchMode()
        print("wrote feature 5 = 02 01 (multi-input)")
    } catch {
        fail(4, "\(error)")
    }
    do {
        let mode = try d.getFeature(reportID: DeviceMode.reportID, maxLength: 8)
        print("feature 5 after write: \(Formatting.hex(mode))  mode=\(mode.first.map(String.init) ?? "?")")
    } catch {
        print("feature 5 read after write failed: \(error)")
    }
}

func cmdCapture(_ o: Options) {
    let watcher = PanelWatcher()
    let d = firstPanel(watcher)
    print("device: \(d.summary)")
    print("Input Monitoring: \(InputMonitoring.status().rawValue)")

    do {
        try d.open(seize: o.seize)
        print("opened\(o.seize ? " with seize" : "")")
    } catch {
        fail(3, "\(error)")
    }
    if o.writeMode {
        do { try d.setMultiTouchMode(); print("device mode set to multi-input") } catch { print("warning: \(error)") }
    }

    var captured: [CapturedReport] = []
    var count = 0
    var tracker = ContactTracker()
    let start = HostClock.nowSeconds()

    d.startReports { bytes, t in
        count += 1
        let ns = HostClock.nowNanoseconds()
        if o.out != nil { captured.append(CapturedReport(nanoseconds: ns, bytes: bytes)) }
        guard !o.quiet else { return }
        let rel = String(format: "%8.3f", t - start)
        if let frame = try? ReportParser.parse(bytes) {
            let touches = tracker.ingest(frame, at: t).map(Formatting.describe).joined(separator: ", ")
            print("\(rel) id=\(bytes[0]) len=\(bytes.count) \(Formatting.describe(frame))  \(touches)")
        } else {
            print("\(rel) id=\(bytes[0]) len=\(bytes.count) raw=\(Formatting.hex(bytes))")
        }
    }

    // The manager must be scheduled for the device's callbacks to fire.
    watcher.start(runLoop: CFRunLoopGetMain())

    var finished = false
    func finish() {
        if finished { return }
        finished = true
        d.close()
        print("\(count) reports in \(String(format: "%.1f", HostClock.nowSeconds() - start)) s")
        if let out = o.out {
            do {
                try FixtureFile.write(captured, to: URL(fileURLWithPath: out))
                print("wrote \(captured.count) reports to \(out)")
            } catch {
                fputs("failed to write \(out): \(error)\n", stderr)
            }
        }
        exit(0)
    }

    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { finish() }
    sigint.resume()

    let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + o.seconds, 0, 0, 0) { _ in finish() }
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.defaultMode)
    print("capturing for \(Int(o.seconds)) s, Ctrl-C to stop early. Touch the panel.")
    CFRunLoopRun()
}

func cmdWatchCursor(_ o: Options) {
    print("watching the pointer for \(Int(o.seconds)) s without opening the panel. Touch it now.")
    print("If the pointer moves, macOS is generating pointer events from the digitizer on its own.")
    var last = CGEvent(source: nil)?.location ?? .zero
    let start = HostClock.nowSeconds()
    var moves = 0
    while HostClock.nowSeconds() - start < o.seconds {
        usleep(20_000)
        guard let p = CGEvent(source: nil)?.location else { continue }
        if hypot(p.x - last.x, p.y - last.y) >= 1 {
            moves += 1
            print(String(format: "%8.3f  pointer at (%.0f, %.0f)", HostClock.nowSeconds() - start, p.x, p.y))
            last = p
        }
    }
    print("\(moves) movements observed")
}

func cmdPermissions(_ o: Options) {
    print("Input Monitoring: \(InputMonitoring.status().rawValue)")
    if o.request {
        print("requesting... (a system prompt may appear)")
        print("Input Monitoring: \(InputMonitoring.request().rawValue)")
    }
}

// MARK: main

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    print(usage)
    exit(1)
}
let options = parse(Array(argv.dropFirst()))

switch command {
case "list": cmdList()
case "descriptor": cmdDescriptor()
case "features": cmdFeatures(options)
case "capture": cmdCapture(options)
case "watch-cursor": cmdWatchCursor(options)
case "permissions": cmdPermissions(options)
case "-h", "--help", "help": print(usage)
default:
    fputs("unknown command \(command)\n\(usage)", stderr)
    exit(1)
}
