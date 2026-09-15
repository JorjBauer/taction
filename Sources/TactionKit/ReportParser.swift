import Foundation

/// One finger as reported by the panel in a single slot of report ID 6.
public struct Contact: Equatable, Hashable, Codable {
    /// HID Contact Identifier (usage 0x51), 0 to 31. Stable while the finger is down.
    public var id: UInt8
    /// HID Tip Switch (usage 0x42). False in the frame that reports liftoff.
    public var tip: Bool
    /// Absolute X, 0 to 4095, origin top-left in landscape.
    public var x: UInt16
    /// Absolute Y, 0 to 4095, origin top-left in landscape.
    public var y: UInt16

    public init(id: UInt8, tip: Bool, x: UInt16, y: UInt16) {
        self.id = id
        self.tip = tip
        self.x = x
        self.y = y
    }
}

/// One decoded input report (report ID 6).
public struct Frame: Equatable, Codable {
    /// Contact Count (usage 0x54) exactly as reported. In hybrid mode this can exceed
    /// `contacts.count` on the first report of a frame and be zero on continuation reports.
    public var contactCount: UInt8
    /// The non-empty slots, in slot order.
    public var contacts: [Contact]
    /// Scan Time (usage 0x56) in 100 microsecond units, wraps at 2^31.
    public var scanTime: UInt32

    public init(contactCount: UInt8, contacts: [Contact], scanTime: UInt32) {
        self.contactCount = contactCount
        self.contacts = contacts
        self.scanTime = scanTime
    }
}

public enum ParseError: Error, Equatable {
    case wrongReportID(UInt8)
    case tooShort(Int)
    case empty
}

/// Byte layout of report ID 6, from the panel's own report descriptor.
/// See taction/01-panel-protocol.md.
public enum ReportLayout {
    public static let reportID: UInt8 = 6
    public static let length = 56
    public static let contactCountOffset = 1
    public static let firstSlotOffset = 2
    public static let slotCount = 5
    public static let slotSize = 10
    public static let scanTimeOffset = 52
    public static let maxCoordinate: UInt16 = 4095
    /// Contact Count above this means the frame continues in following reports.
    public static let maxContactsPerReport: UInt8 = 5

    // Offsets inside one slot.
    static let tipOffset = 0
    static let idOffset = 1
    static let xOffset = 2
    static let yOffset = 4
}

public struct ReportParser {
    /// Decode one input report. `bytes[0]` must be the report ID.
    public static func parse(_ bytes: [UInt8]) throws -> Frame {
        guard let first = bytes.first else { throw ParseError.empty }
        guard first == ReportLayout.reportID else { throw ParseError.wrongReportID(first) }
        guard bytes.count >= ReportLayout.length else { throw ParseError.tooShort(bytes.count) }

        let contactCount = bytes[ReportLayout.contactCountOffset]
        var contacts: [Contact] = []
        contacts.reserveCapacity(ReportLayout.slotCount)

        for slot in 0..<ReportLayout.slotCount {
            let base = ReportLayout.firstSlotOffset + slot * ReportLayout.slotSize
            let tip = bytes[base + ReportLayout.tipOffset] & 0x01 == 1
            let id = bytes[base + ReportLayout.idOffset]
            let x = UInt16(bytes[base + ReportLayout.xOffset]) | UInt16(bytes[base + ReportLayout.xOffset + 1]) << 8
            let y = UInt16(bytes[base + ReportLayout.yOffset]) | UInt16(bytes[base + ReportLayout.yOffset + 1]) << 8

            // An all-zero slot is padding after the last real contact. A slot with tip 0 but
            // nonzero coordinates is a genuine liftoff and must be kept.
            if !tip && id == 0 && x == 0 && y == 0 { continue }
            contacts.append(Contact(id: id, tip: tip, x: x, y: y))
        }

        let t = ReportLayout.scanTimeOffset
        let scanTime = UInt32(bytes[t]) | UInt32(bytes[t + 1]) << 8 | UInt32(bytes[t + 2]) << 16 | UInt32(bytes[t + 3]) << 24
        return Frame(contactCount: contactCount, contacts: contacts, scanTime: scanTime)
    }
}

/// Inverse of `ReportParser`, for tests and synthetic fixtures.
public struct ReportEncoder {
    public static func encode(_ frame: Frame) -> [UInt8] {
        precondition(frame.contacts.count <= ReportLayout.slotCount, "at most 5 slots per report")
        var bytes = [UInt8](repeating: 0, count: ReportLayout.length)
        bytes[0] = ReportLayout.reportID
        bytes[ReportLayout.contactCountOffset] = frame.contactCount
        for (slot, c) in frame.contacts.enumerated() {
            let base = ReportLayout.firstSlotOffset + slot * ReportLayout.slotSize
            bytes[base + ReportLayout.tipOffset] = c.tip ? 1 : 0
            bytes[base + ReportLayout.idOffset] = c.id
            bytes[base + ReportLayout.xOffset] = UInt8(c.x & 0xFF)
            bytes[base + ReportLayout.xOffset + 1] = UInt8(c.x >> 8)
            bytes[base + ReportLayout.yOffset] = UInt8(c.y & 0xFF)
            bytes[base + ReportLayout.yOffset + 1] = UInt8(c.y >> 8)
        }
        let t = ReportLayout.scanTimeOffset
        bytes[t] = UInt8(frame.scanTime & 0xFF)
        bytes[t + 1] = UInt8((frame.scanTime >> 8) & 0xFF)
        bytes[t + 2] = UInt8((frame.scanTime >> 16) & 0xFF)
        bytes[t + 3] = UInt8((frame.scanTime >> 24) & 0xFF)
        return bytes
    }
}

/// The device-mode feature report (report ID 5) that switches the panel into multitouch reporting.
public enum DeviceMode {
    public static let reportID: UInt8 = 5
    public static let mouse: UInt8 = 0
    public static let singleInput: UInt8 = 1
    public static let multiInput: UInt8 = 2
    public static let deviceIdentifier: UInt8 = 1

    /// Payload without the report ID byte. `PanelDevice.setFeature` prepends the ID, because the
    /// HID layer sends the buffer as the raw SET_REPORT data stage (verified on the panel).
    public static func payload(mode: UInt8) -> [UInt8] { [mode, deviceIdentifier] }
}

/// Feature report 0x0E: Contact Count Maximum and Device Index.
public enum ContactCountMaximum {
    public static let reportID: UInt8 = 0x0E
}
