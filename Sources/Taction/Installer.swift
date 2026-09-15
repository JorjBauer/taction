import AppKit
import ServiceManagement
import TactionDaemon

/// First-launch housekeeping: land in the Applications folder, open at login, retire the old CLI agent.
enum Installer {
    static let legacyAgentLabel = "org.jorj.tactiond"

    // MARK: Move to Applications

    /// If the app is running from somewhere other than an Applications folder (a DMG, Downloads),
    /// offer to copy it there and relaunch. Returns true when a relaunch is under way.
    static func offerMoveToApplicationsIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Applications/") || path.hasPrefix("\(home)/Applications/") {
            Log.info("app", "running from \(path); no move needed")
            return false
        }
        // "Don't Move" is remembered for this location and version only, so a later copy elsewhere,
        // or an updated build in the same place, asks again.
        let declineKey = "\(path)@\(AppInfo.version)"
        if UserDefaults.standard.string(forKey: AppInfo.Defaults.declinedMoveToApplications) == declineKey {
            Log.info("app", "running from \(path); move to Applications was declined for this copy")
            return false
        }
        Log.info("app", "running from \(path); offering to move to Applications")

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = AppInfo.appIcon
        alert.messageText = "Move \(AppInfo.name) to the Applications folder?"
        alert.informativeText = "\(AppInfo.name) runs in the menu bar and opens at login, so it should live in Applications. It can move itself there now and reopen."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don\u{2019}t Move")
        NSApp.bringForward()
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(declineKey, forKey: AppInfo.Defaults.declinedMoveToApplications)
            Log.info("app", "user declined the move")
            return false
        }

        let fm = FileManager.default
        var destDir = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if !fm.isWritableFile(atPath: destDir.path) {
            destDir = URL(fileURLWithPath: "\(home)/Applications", isDirectory: true)
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let dest = destDir.appendingPathComponent(bundleURL.lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: bundleURL, to: dest)
            Log.info("app", "copied to \(dest.path); relaunching")
            // The user chose "Move", so do not leave a second copy behind to be launched by mistake.
            // A read-only source (a mounted DMG) or a translocated copy just stays where it is.
            if fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path), !path.contains("/AppTranslocation/") {
                if (try? fm.trashItem(at: bundleURL, resultingItemURL: nil)) != nil {
                    Log.info("app", "moved the original at \(path) to the Trash")
                }
            }
            relaunch(at: dest)
            return true
        } catch {
            Log.error("app", "move to Applications failed: \(error)")
            let failure = NSAlert(error: error)
            failure.messageText = "Could not move \(AppInfo.name)"
            failure.runModal()
            return false
        }
    }

    /// Start a copy at `url` after this process exits, then quit.
    static func relaunch(at url: URL) {
        let script = "sleep 1; /usr/bin/open \"\(url.path)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Login item

    /// Register as a login item the first time. The user can turn it off under
    /// System Settings > General > Login Items, and this never re-registers behind their back.
    static func registerLoginItemOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppInfo.Defaults.loginItemRegistered) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status != .enabled {
                try service.register()
                Log.info("app", "registered as a login item")
            }
            defaults.set(true, forKey: AppInfo.Defaults.loginItemRegistered)
        } catch {
            Log.error("app", "login item registration failed: \(error)")
        }
    }

    // MARK: Legacy CLI agent

    /// Earlier builds installed a headless LaunchAgent. It would fight the app for the panel, so stop and remove it.
    static func stopLegacyAgent() {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyAgentLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(legacyAgentLabel)"]
        p.standardError = FileHandle.nullDevice    // "No such process" when it was never loaded
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: plist)
        Log.info("app", "removed the legacy agent \(legacyAgentLabel)\(p.terminationStatus == 0 ? " (it was running)" : "")")
    }

    /// A foreground `tactiond` (a debugging session) would double-post every touch.
    static func warnIfHeadlessDaemonRunning() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "tactiond"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return }
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        Log.error("app", "tactiond is running (pid \(pids)); both would post events")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "tactiond is already running"
        alert.informativeText = "The command-line daemon (pid \(pids)) drives the same panel. Quit it, or quit \(AppInfo.name), or every touch will be posted twice."
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Quit \(AppInfo.name)")
        NSApp.bringForward()
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
    }
}
