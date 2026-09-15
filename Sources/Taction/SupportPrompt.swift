import AppKit
import TactionDaemon

/// The "please support Taction" ask. Honor system: nothing is gated and nothing changes either way.
/// Shown on every tenth launch until the user says they have already donated.
enum SupportPrompt {
    static let everyNthLaunch = 10

    static func recordLaunchAndMaybeAsk() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: AppInfo.Defaults.launchCount) + 1
        defaults.set(count, forKey: AppInfo.Defaults.launchCount)
        Log.debug("app", "launch \(count)")

        guard !defaults.bool(forKey: AppInfo.Defaults.supported) else { return }
        guard count % everyNthLaunch == 0 else { return }

        // A moment after launch, so the menu bar item is already up and touch already works.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ask() }
    }

    static func ask() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = AppInfo.appIcon
        alert.messageText = "Support \(AppInfo.name)"
        alert.informativeText = "\(AppInfo.name) is free. If you find it useful, please consider supporting it.\n\nNothing is locked and nothing changes either way. This reminder appears every \(everyNthLaunch) launches until you choose \u{201C}Already Did, Thanks\u{201D}."
        alert.addButton(withTitle: "Open the Support Page")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "Already Did, Thanks")

        NSApp.bringForward()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(AppInfo.supportURL)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: AppInfo.Defaults.supported)
        default:
            break
        }
    }
}
