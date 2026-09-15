import AppKit
import TactionKit
import TactionDaemon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var daemon: Daemon?
    private var statusItem: StatusItemController?
    private lazy var about = AboutWindowController()
    private lazy var preferences = PreferencesWindowController()
    private var updater: Updater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppInfo.Defaults.register()
        Log.mirrorToStderr = AppInfo.isDevBuild
        Log.info("app", "Taction \(AppInfo.version) (\(AppInfo.build)) starting\(AppInfo.isDevBuild ? " [development build]" : "") from \(Bundle.main.bundlePath)")

        // The headless CLI agent from earlier versions drives the same panel; the app replaces it.
        Installer.stopLegacyAgent()
        Installer.warnIfHeadlessDaemonRunning()

        if !AppInfo.isDevBuild, Installer.offerMoveToApplicationsIfNeeded() {
            return   // relaunching from the new location
        }

        statusItem = StatusItemController(
            onAbout: { [weak self] in self?.about.show() },
            onPreferences: { [weak self] in self?.preferences.show() },
            onQuit: { NSApp.terminate(nil) })

        startDaemon()

        if !AppInfo.isDevBuild {
            Installer.registerLoginItemOnce()
        }
        Permissions.promptIfNeeded()
        SupportPrompt.recordLaunchAndMaybeAsk()

        updater = Updater()
        if !AppInfo.isDevBuild { updater?.scheduleChecks() }

        // Development aid: TACTION_OPEN=about|preferences opens that window at launch (for screenshots).
        if AppInfo.isDevBuild, let which = ProcessInfo.processInfo.environment["TACTION_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                switch which {
                case "about": self?.about.show()
                case "preferences": self?.preferences.show()
                default: break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemon?.shutdown()
    }

    private func startDaemon() {
        let configURL = TactionConfig.defaultConfigURL
        let config: TactionConfig
        do {
            config = try TactionConfig.loadOrCreate(at: configURL)
        } catch {
            Log.error("app", "config error at \(configURL.path): \(error)")
            let alert = NSAlert()
            alert.messageText = "Taction could not read its configuration"
            alert.informativeText = "\(configURL.path)\n\n\(error.localizedDescription)\n\nFix the file or delete it to regenerate the defaults, then reopen Taction."
            alert.addButton(withTitle: "Quit")
            NSApp.bringForward()
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let d = Daemon(config: config, configURL: configURL, foreground: AppInfo.isDevBuild)
        d.onStatusChange = { [weak self] status in self?.statusItem?.update(with: status) }
        d.start()
        daemon = d
    }
}
