import Testing
import Foundation
import CoreGraphics
@testable import TactionKit

/// Regression tests against reports captured from the real panel with `taction-probe capture`.
///
/// `real-session-2026-09-15.bin`: 474 reports over 10.6 s. The user performed, in order, a
/// one-finger drag, five single taps, two two-finger taps, a two-finger downward drag, and
/// finally rested a palm on the panel (9.6 s to 10.6 s), which the firmware reported as two
/// contacts about 12 cm apart drifting upward. The palm must not produce any action.
@Suite struct RealCaptureTests {
    static func fixture(_ name: String) throws -> [CapturedReport] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"),
                               "fixture \(name).bin missing from Tests/Fixtures")
        return try FixtureFile.read(from: url)
    }

    /// Same stepping the daemon and the replay tool use.
    static func run(_ reports: [CapturedReport], gestures: GestureConfig = GestureConfig()) -> (actions: [OutputAction], pipeline: Pipeline) {
        // Map onto a plausible 1080p display sitting to the right of a built-in one.
        let mapper = DisplayMapper(geometry: DisplayGeometry(frame: CGRect(x: 1800, y: 0, width: 1920, height: 1080)))
        var p = Pipeline(mapper: mapper, gestures: gestures)
        var actions: [OutputAction] = []
        var clock = reports.first?.seconds ?? 0
        for r in reports {
            while p.engine.needsTick && clock + 0.010 < r.seconds {
                clock += 0.010
                actions += p.tick(now: clock)
            }
            clock = r.seconds
            actions += p.ingest(report: r.bytes, at: r.seconds).actions
        }
        var settle = 0
        while p.engine.needsTick && settle < 500 {
            clock += 0.010
            actions += p.tick(now: clock)
            settle += 1
        }
        return (actions, p)
    }

    /// Re-run the pipeline and collect only the actions produced by reports at or after `seconds` from the start.
    static func actionsAfter(seconds: Double, reports: [CapturedReport], t0: Double) -> [OutputAction] {
        let mapper = DisplayMapper(geometry: DisplayGeometry(frame: CGRect(x: 1800, y: 0, width: 1920, height: 1080)))
        var p = Pipeline(mapper: mapper)
        var late: [OutputAction] = []
        var clock = t0
        for r in reports {
            while p.engine.needsTick && clock + 0.010 < r.seconds {
                clock += 0.010
                let a = p.tick(now: clock)
                if clock - t0 >= seconds { late += a }
            }
            clock = r.seconds
            let a = p.ingest(report: r.bytes, at: r.seconds).actions
            if r.seconds - t0 >= seconds { late += a }
        }
        return late
    }

    @Test func everyReportParses() throws {
        let reports = try Self.fixture("real-session-2026-09-15")
        #expect(reports.count == 474)
        var liftoffFrames = 0
        for r in reports {
            let f = try ReportParser.parse(r.bytes)
            #expect(r.bytes.count == ReportLayout.length)
            #expect(f.contactCount >= 1 && f.contactCount <= 2)
            // Contact Count includes fingers reported with tip 0 in their liftoff frame.
            #expect(f.contacts.count == Int(f.contactCount), "slots should equal contact count in non-hybrid frames")
            if f.contacts.contains(where: { !$0.tip }) { liftoffFrames += 1 }
            for c in f.contacts {
                #expect(c.x <= ReportLayout.maxCoordinate && c.y <= ReportLayout.maxCoordinate)
            }
        }
        // The firmware reports every liftoff explicitly: 10 touch sequences in this session.
        #expect(liftoffFrames == 10)
    }

    @Test func sessionRecognizesTheGesturesPerformed() throws {
        let reports = try Self.fixture("real-session-2026-09-15")
        let (actions, p) = Self.run(reports)

        #expect(p.parseErrors == 0)
        #expect(p.engine.state == .idle)
        #expect(!p.engine.isLeftButtonDown)
        #expect(p.tracker.activeCount == 0)

        let downs = actions.filter { if case .leftDown = $0 { return true } else { return false } }.count
        let ups = actions.filter { if case .leftUp = $0 { return true } else { return false } }.count
        let clicks = actions.filter { if case .leftClick = $0 { return true } else { return false } }.count
        let rightClicks = actions.filter { if case .rightClick = $0 { return true } else { return false } }.count
        let scrollBegan = actions.filter { if case .scroll(_, _, _, .began) = $0 { return true } else { return false } }.count
        let scrollEnded = actions.filter { if case .scroll(_, _, _, .ended) = $0 { return true } else { return false } }.count

        #expect(downs == 1 && ups == 1, "one drag: \(downs) down, \(ups) up")
        #expect(clicks == 5, "five taps, got \(clicks)")
        #expect(rightClicks == 2, "two two-finger taps, got \(rightClicks)")
        #expect(scrollBegan == 1 && scrollEnded == 1, "one scroll gesture (the palm must not scroll): \(scrollBegan) began, \(scrollEnded) ended")

        // The scroll was a downward two-finger drag: with natural scrolling the content displacement is positive.
        let totalDy = actions.reduce(0.0) { acc, a in if case .scroll(_, let dy, _, _) = a { return acc + dy } else { return acc } }
        #expect(totalDy > 20, "downward scroll should accumulate positive dy, got \(totalDy)")

        // Nothing at all may be posted while the palm rests on the panel (after 9.5 s).
        let t0 = reports[0].seconds
        let palmActions = Self.actionsAfter(seconds: 9.5, reports: reports, t0: t0)
        #expect(palmActions.isEmpty, "palm produced \(palmActions)")

        // Every point posted lies on the bound display.
        let frame = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        for a in actions {
            switch a {
            case .moveTo(let pt), .leftDown(let pt), .leftUp(let pt), .leftClick(let pt), .rightClick(let pt), .scroll(_, _, let pt, _):
                #expect(frame.contains(pt), "\(a) is off the display")
            case .system:
                Issue.record("no system action was performed in this session, got \(a)")
            }
        }
    }

    @Test func reportTimingIsAsDocumented() throws {
        let reports = try Self.fixture("real-session-2026-09-15")
        // Scan Time restarts at 0 on each new touch and advances about 72 units (7.2 ms) per report.
        let first = try ReportParser.parse(reports[0].bytes)
        #expect(first.scanTime == 0)
        var deltas: [Int] = []
        var prev = first.scanTime
        for r in reports.dropFirst().prefix(100) {
            let f = try ReportParser.parse(r.bytes)
            if f.scanTime > prev { deltas.append(Int(f.scanTime - prev)) }
            prev = f.scanTime
        }
        let avg = Double(deltas.reduce(0, +)) / Double(max(deltas.count, 1))
        #expect(avg > 60 && avg < 85, "expected ~72 (7.2 ms) per report, got \(avg)")
    }
}
