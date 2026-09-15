import AppKit
import ApplicationServices
import TactionHID
import TactionDaemon

/// One alert that names whichever of the two privacy grants is missing and opens the right pane.
enum Permissions {
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let inputMonitoringPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    static func promptIfNeeded() {
        // The daemon has already triggered the system prompts; give them a moment before adding ours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let needAX = !AXIsProcessTrusted()
            let needIM = InputMonitoring.status() != .granted
            guard needAX || needIM else { return }

            var missing: [String] = []
            if needIM { missing.append("Input Monitoring, to receive touches from the panel") }
            if needAX { missing.append("Accessibility, to move the pointer and click") }

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.icon = AppInfo.appIcon
            alert.messageText = "\(AppInfo.name) needs \(missing.count == 2 ? "two permissions" : "a permission")"
            alert.informativeText = missing.map { "\u{2022} \($0)" }.joined(separator: "\n")
                + "\n\nTurn \(AppInfo.name) on in System Settings > Privacy & Security. If it is not listed, use the + button and choose \(AppInfo.name) from the Applications folder. \(AppInfo.name) picks the grants up within a few seconds; no relaunch is needed."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            NSApp.bringForward()
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(needIM ? inputMonitoringPane : accessibilityPane)
                if needIM && needAX {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSWorkspace.shared.open(accessibilityPane) }
                }
            }
            Log.info("app", "permissions missing: \(missing.joined(separator: "; "))")
        }
    }
}
