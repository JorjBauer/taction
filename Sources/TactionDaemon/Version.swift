import Foundation

public enum TactionVersion {
    /// Used when running unbundled (the CLI, or `swift run`). Kept in sync with the VERSION file by scripts/bundle.sh.
    public static let fallback = "0.1.1"

    /// The bundle's marketing version when running as Taction.app, else `fallback`.
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallback
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }
}
