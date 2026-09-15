import Foundation
import os
import TactionKit

/// os_log plus optional stderr mirroring for foreground runs.
public final class Log {
    public static var level: LogLevel = .info
    public static var mirrorToStderr = false

    private static let subsystem = "org.jorj.taction"
    private static var loggers: [String: Logger] = [:]

    /// Plain-text copy of info and error lines, for support reports and remote diagnosis where
    /// `log show` is impractical: ~/Library/Logs/Taction.log. Truncated when it passes 2 MB.
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Taction.log")
    private static var fileHandle: FileHandle? = {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int), size > 2_000_000 {
            try? fm.removeItem(at: fileURL)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: fileURL)
        _ = try? h?.seekToEnd()
        return h
    }()

    private static func appendToFile(_ level: String, _ category: String, _ message: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(level) [\(category)] \(message)\n"
        fileHandle?.write(Data(line.utf8))
    }

    private static func logger(_ category: String) -> Logger {
        if let l = loggers[category] { return l }
        let l = Logger(subsystem: subsystem, category: category)
        loggers[category] = l
        return l
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    public static func error(_ category: String, _ message: String) {
        logger(category).error("\(message, privacy: .public)")
        appendToFile("ERR", category, message)
        if mirrorToStderr { fputs("\(stamp()) ERR [\(category)] \(message)\n", stderr) }
    }

    public static func info(_ category: String, _ message: String) {
        guard level != .error else { return }
        logger(category).info("\(message, privacy: .public)")
        appendToFile("INF", category, message)
        if mirrorToStderr { fputs("\(stamp()) INF [\(category)] \(message)\n", stderr) }
    }

    public static func debug(_ category: String, _ message: @autoclosure () -> String) {
        guard level == .debug else { return }
        let m = message()
        logger(category).debug("\(m, privacy: .public)")
        appendToFile("DBG", category, m)
        if mirrorToStderr { fputs("\(stamp()) DBG [\(category)] \(m)\n", stderr) }
    }
}
