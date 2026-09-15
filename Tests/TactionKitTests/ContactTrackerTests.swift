import Testing
@testable import TactionKit

@Suite struct ContactTrackerTests {
    func f(_ id: UInt8, _ x: UInt16, _ y: UInt16, tip: Bool = true) -> Contact { Contact(id: id, tip: tip, x: x, y: y) }

    @Test func downMoveUpByTipSwitch() {
        var t = ContactTracker()
        #expect(t.ingest(Frame(contactCount: 1, contacts: [f(0, 10, 10)], scanTime: 1), at: 1.0) == [.down(id: 0, x: 10, y: 10, t: 1.0)])
        #expect(t.ingest(Frame(contactCount: 1, contacts: [f(0, 12, 10)], scanTime: 2), at: 1.01) == [.move(id: 0, x: 12, y: 10, t: 1.01)])
        #expect(t.ingest(Frame(contactCount: 0, contacts: [f(0, 12, 10, tip: false)], scanTime: 3), at: 1.02) == [.up(id: 0, x: 12, y: 10, t: 1.02)])
        #expect(t.activeCount == 0)
    }

    @Test func liftoffByVanishing() {
        var t = ContactTracker()
        _ = t.ingest(Frame(contactCount: 2, contacts: [f(0, 10, 10), f(1, 50, 50)], scanTime: 1), at: 1.0)
        // Next complete frame only mentions finger 1: finger 0 is gone.
        let events = t.ingest(Frame(contactCount: 1, contacts: [f(1, 51, 50)], scanTime: 2), at: 1.01)
        #expect(events == [.move(id: 1, x: 51, y: 50, t: 1.01), .up(id: 0, x: 10, y: 10, t: 1.01)])
        #expect(t.activeIDs == [1])
    }

    @Test func emptyFrameLiftsEverything() {
        var t = ContactTracker()
        _ = t.ingest(Frame(contactCount: 2, contacts: [f(0, 10, 10), f(1, 50, 50)], scanTime: 1), at: 1.0)
        let events = t.ingest(Frame(contactCount: 0, contacts: [], scanTime: 2), at: 1.01)
        #expect(events == [.up(id: 0, x: 10, y: 10, t: 1.01), .up(id: 1, x: 50, y: 50, t: 1.01)])
        #expect(t.activeCount == 0)
    }

    @Test func identifierReuseIsANewFinger() {
        var t = ContactTracker()
        _ = t.ingest(Frame(contactCount: 1, contacts: [f(0, 10, 10)], scanTime: 1), at: 1.0)
        _ = t.ingest(Frame(contactCount: 0, contacts: [], scanTime: 2), at: 1.01)
        let events = t.ingest(Frame(contactCount: 1, contacts: [f(0, 500, 500)], scanTime: 3), at: 1.02)
        #expect(events == [.down(id: 0, x: 500, y: 500, t: 1.02)])
    }

    @Test func hybridContinuationDoesNotLiftFingers() {
        var t = ContactTracker()
        // Six fingers: first report carries 5 with count 6, second carries the sixth with count 0 and the same scan time.
        let first = (0..<5).map { f(UInt8($0), UInt16(100 * $0), 100) }
        var events = t.ingest(Frame(contactCount: 6, contacts: first, scanTime: 10), at: 1.0)
        #expect(events.count == 5)
        events = t.ingest(Frame(contactCount: 0, contacts: [f(5, 900, 100)], scanTime: 10), at: 1.001)
        #expect(events == [.down(id: 5, x: 900, y: 100, t: 1.001)])
        #expect(t.activeCount == 6)

        // Next scan: only fingers 0 and 5 remain, reported as a complete frame.
        events = t.ingest(Frame(contactCount: 2, contacts: [f(0, 0, 100), f(5, 900, 100)], scanTime: 11), at: 1.01)
        let ups = events.filter { if case .up = $0 { return true } else { return false } }.map(\.id).sorted()
        #expect(ups == [1, 2, 3, 4])
        #expect(t.activeIDs == [0, 5])
    }

    @Test func hybridFrameFollowedByNewScanLiftsUnmentioned() {
        var t = ContactTracker()
        let first = (0..<5).map { f(UInt8($0), UInt16(100 * $0), 100) }
        _ = t.ingest(Frame(contactCount: 6, contacts: first, scanTime: 10), at: 1.0)
        // The continuation never arrives; a new incomplete scan mentions only 0..2 in its first report.
        let events = t.ingest(Frame(contactCount: 6, contacts: Array(first.prefix(3)), scanTime: 11), at: 1.01)
        // Fingers 3 and 4 were not in the previous scan's continuation either, so they lift only when
        // the *next* scan shows they are absent. Here nothing lifts yet: the new scan is still incomplete.
        let ups = events.filter { if case .up = $0 { return true } else { return false } }
        #expect(ups.isEmpty)
        // Complete the scan with nothing more, then a fresh complete frame: 3 and 4 lift now.
        let next = t.ingest(Frame(contactCount: 3, contacts: Array(first.prefix(3)), scanTime: 12), at: 1.02)
        let ups2 = next.filter { if case .up = $0 { return true } else { return false } }.map(\.id).sorted()
        #expect(ups2 == [3, 4])
    }

    @Test func releaseAllEmitsUpForEachActive() {
        var t = ContactTracker()
        _ = t.ingest(Frame(contactCount: 2, contacts: [f(2, 10, 10), f(7, 50, 50)], scanTime: 1), at: 1.0)
        #expect(t.releaseAll(at: 2.0) == [.up(id: 2, x: 10, y: 10, t: 2.0), .up(id: 7, x: 50, y: 50, t: 2.0)])
        #expect(t.activeCount == 0)
        #expect(t.releaseAll(at: 3.0).isEmpty)
    }
}
