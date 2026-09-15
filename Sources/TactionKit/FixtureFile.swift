import Foundation

/// One captured input report with its host arrival time.
public struct CapturedReport: Equatable {
    /// Host monotonic time in nanoseconds at arrival.
    public var nanoseconds: UInt64
    public var bytes: [UInt8]

    public init(nanoseconds: UInt64, bytes: [UInt8]) {
        self.nanoseconds = nanoseconds
        self.bytes = bytes
    }

    public var seconds: Double { Double(nanoseconds) / 1_000_000_000 }
}

/// The `taction-probe capture --out` file format, also what the tests replay.
///
/// Records are concatenated. Each record is a 16-byte little-endian header
/// (u64 nanoseconds, u32 length, u32 reserved zero) followed by `length` report bytes.
public enum FixtureFile {
    public static let headerSize = 16

    public enum ReadError: Error, Equatable { case truncatedHeader(offset: Int), truncatedRecord(offset: Int, expected: Int) }

    public static func encode(_ reports: [CapturedReport]) -> Data {
        var data = Data()
        for r in reports {
            var ns = r.nanoseconds.littleEndian
            var len = UInt32(r.bytes.count).littleEndian
            var zero = UInt32(0)
            data.append(Data(bytes: &ns, count: 8))
            data.append(Data(bytes: &len, count: 4))
            data.append(Data(bytes: &zero, count: 4))
            data.append(contentsOf: r.bytes)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> [CapturedReport] {
        var out: [CapturedReport] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            guard offset + headerSize <= bytes.count else { throw ReadError.truncatedHeader(offset: offset) }
            var ns: UInt64 = 0
            for i in 0..<8 { ns |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
            var len: UInt32 = 0
            for i in 0..<4 { len |= UInt32(bytes[offset + 8 + i]) << (8 * UInt32(i)) }
            let start = offset + headerSize
            let end = start + Int(len)
            guard end <= bytes.count else { throw ReadError.truncatedRecord(offset: offset, expected: Int(len)) }
            out.append(CapturedReport(nanoseconds: ns, bytes: Array(bytes[start..<end])))
            offset = end
        }
        return out
    }

    public static func write(_ reports: [CapturedReport], to url: URL) throws {
        try encode(reports).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> [CapturedReport] {
        try decode(Data(contentsOf: url))
    }
}

/// Builds synthetic captures from a script of frames, for tests and the replay tool.
public struct SyntheticCapture {
    public private(set) var reports: [CapturedReport] = []
    private var scanTime: UInt32 = 1000
    private var nanoseconds: UInt64

    public init(startSeconds: Double = 1.0) {
        nanoseconds = UInt64(startSeconds * 1_000_000_000)
    }

    /// Append one report `dtMs` after the previous one.
    public mutating func frame(_ contacts: [Contact], contactCount: UInt8? = nil, dtMs: Double = 10) {
        nanoseconds += UInt64(dtMs * 1_000_000)
        scanTime = scanTime &+ UInt32(dtMs * 10)
        let f = Frame(contactCount: contactCount ?? UInt8(contacts.filter { $0.tip }.count), contacts: contacts, scanTime: scanTime)
        reports.append(CapturedReport(nanoseconds: nanoseconds, bytes: ReportEncoder.encode(f)))
    }

    /// Append a frame that reports every finger lifted.
    public mutating func allUp(dtMs: Double = 10) {
        frame([], contactCount: 0, dtMs: dtMs)
    }

    public var lastSeconds: Double { Double(nanoseconds) / 1_000_000_000 }
}
