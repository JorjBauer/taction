import AppKit
import ApplicationServices
import TactionHID

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private var autoUpdateBox: NSButton!
    private var inputMonitoringRow: PermissionRow!
    private var accessibilityRow: PermissionRow!
    private var refreshTimer: Timer?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(AppInfo.name) Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
    }

    func show() {
        autoUpdateBox.state = UserDefaults.standard.bool(forKey: AppInfo.Defaults.autoApplyUpdates) ? .on : .off
        refresh()
        // Grants can change while the window is open; poll so the indicators follow System Settings.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        NSApp.bringForward()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        inputMonitoringRow.setGranted(InputMonitoring.status() == .granted)
        accessibilityRow.setGranted(AXIsProcessTrusted())
    }

    private func makeContent() -> NSView {
        // Updates
        let updatesHeader = sectionHeader("Updates")
        autoUpdateBox = NSButton(checkboxWithTitle: "Automatically apply updates", target: self, action: #selector(toggleAutoUpdate))
        let updatesNote = note("\(AppInfo.name) checks GitHub Releases once a day. With this on, a new version installs itself and \(AppInfo.name) reopens. With it off, you are asked first.")

        // Permissions
        let permissionsHeader = sectionHeader("Permissions")
        inputMonitoringRow = PermissionRow(
            name: "Input Monitoring",
            purpose: "to receive touches from the panel",
            settingsURL: Permissions.inputMonitoringPane)
        accessibilityRow = PermissionRow(
            name: "Accessibility",
            purpose: "to move the pointer, click, scroll, and type shortcuts",
            settingsURL: Permissions.accessibilityPane)
        let permissionsNote = note("Both are required. Turn \(AppInfo.name) on under System Settings > Privacy & Security; if it is not listed, use the + button and choose it from Applications. Changes are picked up within a few seconds, no relaunch needed.")

        let stack = NSStackView(views: [
            updatesHeader, autoUpdateBox, updatesNote,
            separator(),
            permissionsHeader, inputMonitoringRow, accessibilityRow, permissionsNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: updatesNote)
        stack.setCustomSpacing(16, after: separator(placeholder: true))
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for row in [inputMonitoringRow!, accessibilityRow!] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 440),
        ])
        return container
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private var separatorView: NSBox?
    private func separator(placeholder: Bool = false) -> NSBox {
        if placeholder, let existing = separatorView { return existing }
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 400).isActive = true
        separatorView = box
        return box
    }

    @objc private func toggleAutoUpdate() {
        UserDefaults.standard.set(autoUpdateBox.state == .on, forKey: AppInfo.Defaults.autoApplyUpdates)
    }
}

/// One permission: status icon, name and purpose, and the state in words. When the grant is
/// missing, the state text is itself a link to the right System Settings pane.
final class PermissionRow: NSStackView {
    private let icon = NSImageView()
    private let grantedLabel = NSTextField(labelWithString: "Granted")
    private let missingLink: LinkButton

    init(name: String, purpose: String, settingsURL: URL) {
        missingLink = LinkButton(title: "Not granted", url: settingsURL, color: .systemRed,
                                 font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium))
        super.init(frame: .zero)
        missingLink.toolTip = "Open System Settings > Privacy & Security"

        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let purposeLabel = NSTextField(labelWithString: purpose)
        purposeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        purposeLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [nameLabel, purposeLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        grantedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        grantedLabel.textColor = .systemGreen
        grantedLabel.setContentHuggingPriority(.required, for: .horizontal)
        missingLink.setContentHuggingPriority(.required, for: .horizontal)

        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        addView(icon, in: .leading)
        addView(text, in: .leading)
        addView(grantedLabel, in: .trailing)
        addView(missingLink, in: .trailing)
        setGranted(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setGranted(_ granted: Bool) {
        let symbol = granted ? "checkmark.circle.fill" : "xmark.circle.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: granted ? "granted" : "not granted")
        icon.contentTintColor = granted ? .systemGreen : .systemRed
        grantedLabel.isHidden = !granted
        missingLink.isHidden = granted
    }
}
