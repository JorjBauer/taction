import AppKit

final class AboutWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About \(AppInfo.name)"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.contentView = makeContent()
    }

    func show() {
        NSApp.bringForward()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeContent() -> NSView {
        let icon = NSImageView(image: AppInfo.appIcon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let name = NSTextField(labelWithString: AppInfo.name)
        name.font = .boldSystemFont(ofSize: 20)

        let version = NSTextField(labelWithString: "Version \(AppInfo.version) (\(AppInfo.build))")
        version.textColor = .secondaryLabelColor

        let tagline = NSTextField(wrappingLabelWithString: AppInfo.tagline)
        tagline.alignment = .center

        let copyright = NSTextField(labelWithString: AppInfo.copyright)
        let license = NSTextField(labelWithString: "Released under the MIT License.")
        license.textColor = .secondaryLabelColor

        let support = LinkButton(title: "Support \(AppInfo.name) on Ko-fi", url: AppInfo.supportURL)
        let source = LinkButton(title: "Source on GitHub", url: AppInfo.sourceURL)

        let shareware = NSTextField(wrappingLabelWithString: "\(AppInfo.name) is free and nothing is locked. If it is useful to you, please consider a donation.")
        shareware.alignment = .center
        shareware.textColor = .secondaryLabelColor
        shareware.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [icon, name, version, tagline, copyright, license, shareware, support, source])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(12, after: tagline)
        stack.setCustomSpacing(12, after: license)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 360),
        ])
        return container
    }
}

/// A borderless blue underlined button that opens a URL.
final class LinkButton: NSButton {
    private let url: URL

    init(title: String, url: URL, color: NSColor = .linkColor, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) {
        self.url = url
        super.init(frame: .zero)
        isBordered = false
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: font,
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
        target = self
        action = #selector(open)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func open() {
        NSWorkspace.shared.open(url)
    }
}
