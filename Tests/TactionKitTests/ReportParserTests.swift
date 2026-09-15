import Testing
@testable import TactionKit

@Suite struct ReportParserTests {
    /// Hand-assembled from the layout in 01-panel-protocol.md: two fingers down.
    static let twoFingers: [UInt8] = {
        var b = [UInt8](repeating: 0, count: 56)
        b[0] = 6
        b[1] = 2
        // slot 0: tip, id 0, x 0x0800 (2048), y 0x0400 (1024)
        b[2] = 1; b[3] = 0; b[4] = 0x00; b[5] = 0x08; b[6] = 0x00; b[7] = 0x04
        // slot 1: tip, id 1, x 0x0FFF, y 0x0001
        b[12] = 1; b[13] = 1; b[14] = 0xFF; b[15] = 0x0F; b[16] = 0x01; b[17] = 0x00
        // scan time 0x00012345
        b[52] = 0x45; b[53] = 0x23; b[54] = 0x01; b[55] = 0x00
        return b
    }()

    @Test func parsesTwoFingers() throws {
        let f = try ReportParser.parse(Self.twoFingers)
        #expect(f.contactCount == 2)
        #expect(f.scanTime == 0x12345)
        #expect(f.contacts == [
            Contact(id: 0, tip: true, x: 2048, y: 1024),
            Contact(id: 1, tip: true, x: 4095, y: 1),
        ])
    }

    @Test func liftoffSlotIsKeptButPaddingIsDropped() throws {
        var b = Self.twoFingers
        b[1] = 1
        b[2] = 0                 // slot 0 tip 0, coordinates nonzero: a liftoff
        b[12] = 0; b[13] = 0; b[14] = 0; b[15] = 0; b[16] = 0; b[17] = 0   // slot 1 all zero: padding
        let f = try ReportParser.parse(b)
        #expect(f.contacts == [Contact(id: 0, tip: false, x: 2048, y: 1024)])
    }

    @Test func rejectsOtherReportIDs() {
        var b = Self.twoFingers
        b[0] = 3
        #expect(throws: ParseError.wrongReportID(3)) { try ReportParser.parse(b) }
        #expect(throws: ParseError.empty) { try ReportParser.parse([]) }
        #expect(throws: ParseError.tooShort(10)) { try ReportParser.parse([UInt8](repeating: 0, count: 10).withFirst(6)) }
    }

    @Test func acceptsPaddedSixtyFourByteReports() throws {
        let b = Self.twoFingers + [UInt8](repeating: 0, count: 8)
        let f = try ReportParser.parse(b)
        #expect(f.contacts.count == 2)
    }

    @Test func encoderRoundTrips() throws {
        let frame = Frame(contactCount: 7,
                          contacts: [
                              Contact(id: 3, tip: true, x: 1, y: 4095),
                              Contact(id: 9, tip: false, x: 300, y: 2),
                              Contact(id: 31, tip: true, x: 4095, y: 0),
                          ],
                          scanTime: 0x7FFF_FFFF)
        let decoded = try ReportParser.parse(ReportEncoder.encode(frame))
        #expect(decoded == frame)
        #expect(ReportEncoder.encode(frame).count == ReportLayout.length)
    }

    @Test func deviceModePayload() {
        #expect(DeviceMode.reportID == 5)
        #expect(DeviceMode.payload(mode: DeviceMode.multiInput) == [0x02, 0x01])
    }
}

extension Array where Element == UInt8 {
    func withFirst(_ v: UInt8) -> [UInt8] {
        var c = self
        if !c.isEmpty { c[0] = v }
        return c
    }
}
