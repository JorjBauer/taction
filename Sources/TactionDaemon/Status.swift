import Foundation
import TactionKit

/// What `tactiond --status` prints. Rewritten by the daemon on every state change.
public struct Status: Codable {
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var configPath: String
    public var devicePresent = false
    public var deviceOpen = false
    public var seized = false
    public var deviceSummary: String?
    public var display: String?
    public var displayBound = false
    public var accessibility = false
    public var inputMonitoring = "unknown"
    public var posting = false
    public var framesSeen = 0
    public var parseErrors = 0
    public var lastReportAt: Date?
    public var lastError: String?

    public func write() {
        do {
            try FileManager.default.createDirectory(at: TactionConfig.supportDirectory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(self).write(to: TactionConfig.statusURL, options: .atomic)
        } catch {
            Log.error("status", "could not write status: \(error)")
        }
    }

    public static func read() throws -> Status {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Status.self, from: Data(contentsOf: TactionConfig.statusURL))
    }

    public var humanReadable: String {
        var lines: [String] = []
        lines.append("tactiond pid \(pid), started \(startedAt), updated \(updatedAt)")
        lines.append("config:            \(configPath)")
        lines.append("panel:             \(devicePresent ? "present" : "absent")\(deviceOpen ? ", open" : "")\(seized ? ", seized" : "")")
        if let d = deviceSummary { lines.append("                   \(d)") }
        lines.append("display:           \(displayBound ? (display ?? "?") : "NOT BOUND (\(display ?? "no candidate"))")")
        lines.append("accessibility:     \(accessibility ? "granted" : "NOT granted (events will not be delivered)")")
        lines.append("input monitoring:  \(inputMonitoring)")
        lines.append("posting:           \(posting ? "yes" : "no")")
        lines.append("frames:            \(framesSeen) (\(parseErrors) parse errors)\(lastReportAt.map { ", last at \($0)" } ?? "")")
        if let e = lastError { lines.append("last error:        \(e)") }
        return lines.joined(separator: "\n")
    }
}
