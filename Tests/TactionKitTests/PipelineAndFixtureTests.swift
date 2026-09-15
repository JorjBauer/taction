import Testing
import Foundation
import CoreGraphics
@testable import TactionKit

@Suite struct FixtureFileTests {
    @Test func roundTrip() throws {
        let reports = [
            CapturedReport(nanoseconds: 1_000_000_000, bytes: [6, 0, 1, 2, 3]),
            CapturedReport(nanoseconds: 1_010_000_000, bytes: []),
            CapturedReport(nanoseconds: UInt64.max, bytes: [UInt8](repeating: 0xAB, count: 64)),
        ]
        let data = FixtureFile.encode(reports)
        #expect(data.count == 3 * FixtureFile.headerSize + 5 + 0 + 64)
        #expect(try FixtureFile.decode(data) == reports)
    }

    @Test func detectsTruncation() {
        let data = FixtureFile.encode([CapturedReport(nanoseconds: 1, bytes: [1, 2, 3])])
        #expect(throws: FixtureFile.ReadError.truncatedRecord(offset: 0, expected: 3)) {
            try FixtureFile.decode(data.prefix(FixtureFile.headerSize + 1))
        }
        #expect(throws: FixtureFile.ReadError.truncatedHeader(offset: 0)) {
            try FixtureFile.decode(data.prefix(5))
        }
    }
}

@Suite struct ConfigTests {
    @Test func missingKeysTakeDefaults() throws {
        let json = #"{"gestures": {"naturalScrolling": false}, "seize": false}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(TactionConfig.self, from: json)
        #expect(cfg.seize == false)
        #expect(cfg.gestures.naturalScrolling == false)
        #expect(cfg.gestures.tapMaxDurationMs == GestureConfig().tapMaxDurationMs)
        #expect(cfg.calibration == Calibration())
        #expect(cfg.display.nameFallback == "MB16A")
        #expect(cfg.logLevel == .info)
    }

    @Test func emptyObjectIsAllDefaults() throws {
        let cfg = try JSONDecoder().decode(TactionConfig.self, from: "{}".data(using: .utf8)!)
        #expect(cfg == TactionConfig())
    }

    @Test func encodeDecodeRoundTrip() throws {
        var cfg = TactionConfig()
        cfg.calibration.rawMinX = 12
        cfg.display.model = 4242
        cfg.gestures.scrollGain = 1.5
        let data = try JSONEncoder().encode(cfg)
        #expect(try JSONDecoder().decode(TactionConfig.self, from: data) == cfg)
    }
}

/// End-to-end through raw report bytes, using the same synthetic scripts the replay tool offers.
@Suite struct PipelineTests {
    // A 4095-point display makes raw coordinate n land exactly on point n (n / 4095 * 4095).
    let mapper = DisplayMapper(geometry: DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 4095, height: 4095)))

    func run(_ capture: SyntheticCapture) -> (actions: [OutputAction], pipeline: Pipeline) {
        var p = Pipeline(mapper: mapper)
        var actions: [OutputAction] = []
        var clock = capture.reports.first?.seconds ?? 0
        for r in capture.reports {
            while p.engine.needsTick && clock + 0.010 < r.seconds {
                clock += 0.010
                actions += p.tick(now: clock)
            }
            clock = r.seconds
            actions += p.ingest(report: r.bytes, at: r.seconds).actions
        }
        var settle = 0
        while p.engine.needsTick && settle < 500 {      // up to 5 s: enough for momentum to decay
            clock += 0.010
            actions += p.tick(now: clock)
            settle += 1
        }
        return (actions, p)
    }

    @Test func tapThroughRawBytes() {
        var c = SyntheticCapture()
        c.frame([Contact(id: 0, tip: true, x: 2048, y: 1024)])
        c.frame([Contact(id: 0, tip: true, x: 2049, y: 1024)])
        c.frame([Contact(id: 0, tip: false, x: 2049, y: 1024)], contactCount: 0)
        let (actions, p) = run(c)
        #expect(actions == [.leftClick(CGPoint(x: 2048, y: 1024))])
        #expect(p.parseErrors == 0)
        #expect(p.framesSeen == 3)
    }

    @Test func twoFingerScrollThroughRawBytes() {
        var c = SyntheticCapture()
        c.frame([Contact(id: 0, tip: true, x: 2000, y: 1000)])
        c.frame([Contact(id: 0, tip: true, x: 2000, y: 1000), Contact(id: 1, tip: true, x: 2300, y: 1000)], dtMs: 15)
        for k in 1...10 {
            let y = UInt16(1000 + k * 30)
            c.frame([Contact(id: 0, tip: true, x: 2000, y: y), Contact(id: 1, tip: true, x: 2300, y: y)])
        }
        c.allUp()
        let (actions, p) = run(c)
        let phases = actions.compactMap { a -> ScrollPhase? in if case .scroll(_, _, _, let ph) = a { return ph } else { return nil } }
        #expect(phases.first == .began)
        #expect(phases.contains(.ended))
        // This synthetic scroll is fast (about 1400 pt/s), so inertia follows the finger-driven phases.
        #expect(phases.last == .momentumEnded)
        #expect(!actions.contains { if case .leftDown = $0 { return true } else { return false } })
        #expect(p.engine.state == .idle)
    }

    @Test func vendorReportsAreCountedNotFatal() {
        var p = Pipeline(mapper: mapper)
        let r = p.ingest(report: [3] + [UInt8](repeating: 0, count: 63), at: 1.0)
        #expect(r.frame == nil)
        #expect(p.parseErrors == 1)
    }

    @Test func releaseAllDuringDragReleasesButton() {
        var p = Pipeline(mapper: mapper)
        var c = SyntheticCapture()
        c.frame([Contact(id: 0, tip: true, x: 100, y: 100)])
        c.frame([Contact(id: 0, tip: true, x: 400, y: 100)], dtMs: 50)    // past the arbitration window
        var actions: [OutputAction] = []
        for r in c.reports { actions += p.ingest(report: r.bytes, at: r.seconds).actions }
        #expect(p.engine.isLeftButtonDown)
        actions += p.releaseAll(at: c.lastSeconds + 1)
        #expect(!p.engine.isLeftButtonDown)
        #expect(actions.last == .leftUp(CGPoint(x: 400, y: 100)))
        #expect(p.tracker.activeCount == 0)
    }

    @Test func releaseAllDuringPendingTouchEmitsNoClick() {
        var p = Pipeline(mapper: mapper)
        var c = SyntheticCapture()
        c.frame([Contact(id: 0, tip: true, x: 100, y: 100)])
        for r in c.reports { _ = p.ingest(report: r.bytes, at: r.seconds) }
        // Unplug one second later: the synthesized lift must not become a long press or a tap.
        let actions = p.releaseAll(at: c.lastSeconds + 1)
        #expect(actions.isEmpty)
        #expect(p.engine.state == .idle)
        #expect(p.tracker.activeCount == 0)
    }
}
