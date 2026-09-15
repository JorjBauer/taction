import Foundation

/// How the daemon finds the ZenScreen among the online displays.
public struct DisplayBinding: Codable, Equatable {
    /// CGDisplayVendorNumber of the panel's display. The MB16AMT reports 1715 (0x06B3, PNP ID
    /// "AUS"), read from the live display on 2026-09-15. Nil means "match by name only".
    public var vendor: UInt32?
    /// CGDisplayModelNumber. The MB16AMT reports 5729. Nil means "any model from that vendor".
    public var model: UInt32?
    /// Substring of NSScreen.localizedName used when vendor and model do not match.
    /// The live name is "ASUS MB16AMT".
    public var nameFallback: String = "MB16A"

    public init(vendor: UInt32? = 1715, model: UInt32? = 5729, nameFallback: String = "MB16A") {
        self.vendor = vendor
        self.model = model
        self.nameFallback = nameFallback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try c.decodeIfPresent(UInt32.self, forKey: .vendor)
        model = try c.decodeIfPresent(UInt32.self, forKey: .model)
        nameFallback = try c.decodeIfPresent(String.self, forKey: .nameFallback) ?? "MB16A"
    }
}

public enum LogLevel: String, Codable, Equatable { case error, info, debug }

/// The whole daemon configuration. Every key is optional in the file; missing keys take defaults.
public struct TactionConfig: Codable, Equatable {
    public var display = DisplayBinding()
    public var calibration = Calibration()
    public var gestures = GestureConfig()
    /// Open the HID device with kIOHIDOptionsTypeSeizeDevice. Off by default: verified
    /// 2026-09-15 that macOS 26 generates no pointer events from this panel on its own and that
    /// input reports arrive through a shared open once Input Monitoring is granted.
    public var seize = false
    /// Lift all fingers if no report arrives for this long while fingers are down.
    public var staleContactTimeoutMs: Double = 500
    public var logLevel = LogLevel.info

    public static let vendorID: UInt32 = 0x0EEF
    public static let productID: UInt32 = 0xC000

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decodeIfPresent(DisplayBinding.self, forKey: .display) ?? display
        calibration = try c.decodeIfPresent(Calibration.self, forKey: .calibration) ?? calibration
        gestures = try c.decodeIfPresent(GestureConfig.self, forKey: .gestures) ?? gestures
        seize = try c.decodeIfPresent(Bool.self, forKey: .seize) ?? seize
        staleContactTimeoutMs = try c.decodeIfPresent(Double.self, forKey: .staleContactTimeoutMs) ?? staleContactTimeoutMs
        logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? logLevel
    }

    // MARK: File locations

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Taction", isDirectory: true)
    }
    public static var defaultConfigURL: URL { supportDirectory.appendingPathComponent("config.json") }
    public static var statusURL: URL { supportDirectory.appendingPathComponent("status.json") }
    public static var calibrationLockURL: URL { supportDirectory.appendingPathComponent("calibrating.lock") }

    public static func load(from url: URL = defaultConfigURL) throws -> TactionConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(TactionConfig.self, from: data)
    }

    public func write(to url: URL = defaultConfigURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Load the config, or create a default file if none exists.
    public static func loadOrCreate(at url: URL = defaultConfigURL) throws -> TactionConfig {
        if FileManager.default.fileExists(atPath: url.path) { return try load(from: url) }
        let cfg = TactionConfig()
        try cfg.write(to: url)
        return cfg
    }
}
