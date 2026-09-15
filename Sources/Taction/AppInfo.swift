import AppKit
import TactionDaemon

enum AppInfo {
    static let name = "Taction"
    static let bundleIdentifier = "org.jorj.Taction"
    static var version: String { TactionVersion.current }
    static var build: String { TactionVersion.build }
    static let copyright = "Copyright (c) 2026 Jorj Bauer"
    static let tagline = "Touchscreen support for the ASUS ZenScreen Touch MB16AMT."
    static let supportURL = URL(string: "https://ko-fi.com/jorjbauer")!

    /// "owner/repo" on GitHub. Releases there are what the updater checks. Set in Info.plist.
    static var updateRepo: String {
        Bundle.main.object(forInfoDictionaryKey: "TactionUpdateRepo") as? String ?? "JorjBauer/Taction"
    }
    static var sourceURL: URL { URL(string: "https://github.com/\(updateRepo)")! }

    /// Running from `swift run` or from a bundle inside the package's build directory. Development
    /// builds skip the installer prompts, the login item, and update checks.
    static var isDevBuild: Bool {
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundlePath.contains("/.build/")
    }

    static var appIcon: NSImage {
        if let icon = NSApp.applicationIconImage, Bundle.main.bundleIdentifier != nil { return icon }
        return NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: name) ?? NSImage()
    }

    enum Defaults {
        static let autoApplyUpdates = "autoApplyUpdates"
        static let launchCount = "launchCount"
        static let supported = "supported"
        static let loginItemRegistered = "loginItemRegistered"
        static let declinedMoveToApplications = "declinedMoveToApplications"
        static let skippedUpdateVersion = "skippedUpdateVersion"

        static func register() {
            UserDefaults.standard.register(defaults: [autoApplyUpdates: true])
        }
    }
}

extension NSApplication {
    /// Accessory apps are never active, so windows and alerts need an explicit activation to come forward.
    func bringForward() {
        activate(ignoringOtherApps: true)
    }
}
