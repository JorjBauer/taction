import AppKit
import TactionDaemon

/// The app's only presence: a status item with About, Preferences, and Quit.
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let onAbout: () -> Void
    private let onPreferences: () -> Void
    private let onQuit: () -> Void

    init(onAbout: @escaping () -> Void, onPreferences: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onAbout = onAbout
        self.onPreferences = onPreferences
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "\(AppInfo.name): starting"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "About \(AppInfo.name)", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Preferences\u{2026}", action: #selector(preferences), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }

    /// Reflect the daemon's state in the tooltip and the icon's weight, without adding menu items.
    func update(with status: Status) {
        guard let button = item.button else { return }
        var parts: [String] = []
        if status.devicePresent && !status.deviceOpen && (status.lastError ?? "").hasPrefix("unsupported panel") {
            parts.append("unsupported panel connected (see log)")
        } else if status.devicePresent {
            parts.append(status.posting ? "panel connected" : "panel connected, not posting")
        } else {
            parts.append("panel not connected")
        }
        if !status.accessibility { parts.append("Accessibility not granted") }
        if status.inputMonitoring != "granted" { parts.append("Input Monitoring not granted") }
        button.toolTip = "\(AppInfo.name): " + parts.joined(separator: "; ")
        button.appearsDisabled = !(status.devicePresent && status.posting)
    }

    @objc private func about() { onAbout() }
    @objc private func preferences() { onPreferences() }
    @objc private func quit() { onQuit() }
}
