import Testing
import CoreGraphics
@testable import TactionKit

extension Harness {
    /// Like `send` but advancing the clock first, so velocities are finite.
    mutating func after(ms: Double, _ kind: MappedTouchEvent.Kind, _ id: UInt8, _ x: Double, _ y: Double) {
        clock += ms / 1000
        send(kind, id, x, y)
    }

    var scrollPhases: [ScrollPhase] {
        actions.compactMap { if case .scroll(_, _, _, let p) = $0 { return p } else { return nil } }
    }
    var systemActions: [SystemAction] {
        actions.compactMap { if case .system(let s) = $0 { return s } else { return nil } }
    }
    func scrollTotals() -> (dx: Double, dy: Double) {
        actions.reduce((0.0, 0.0)) { acc, a in
            if case .scroll(let dx, let dy, _, _) = a { return (acc.0 + dx, acc.1 + dy) } else { return acc }
        }
    }
}

@Suite struct LongPressTests {
    @Test func stillPressBecomesRightClick() {
        var h = Harness()
        h.down(0, 100, 100)
        h.wait(ms: 600)
        #expect(h.actions == [.rightClick(CGPoint(x: 100, y: 100))])
        h.up(0, 100, 100)
        #expect(h.engine.state == .idle)
        #expect(!h.buttonDown)
    }

    @Test func slightWobbleStillCountsAsStill() {
        var h = Harness()
        h.down(0, 100, 100)
        h.move(0, 104, 103)
        h.wait(ms: 600)
        #expect(h.actions == [.rightClick(CGPoint(x: 100, y: 100))])
    }

    @Test func movementBeforeTimeoutIsADrag() {
        var h = Harness()
        h.down(0, 100, 100)
        h.wait(ms: 300)
        h.move(0, 140, 100)
        h.wait(ms: 600)
        h.up(0, 140, 100)
        #expect(h.actions == [.leftDown(CGPoint(x: 100, y: 100)), .moveTo(CGPoint(x: 140, y: 100)), .leftUp(CGPoint(x: 140, y: 100))])
    }

    @Test func canBeDisabled() {
        var cfg = GestureConfig()
        cfg.longPressRightClick = false
        var h = Harness(config: cfg)
        h.down(0, 100, 100)
        h.wait(ms: 600)
        #expect(!h.actions.contains { if case .rightClick = $0 { return true } else { return false } })
        #expect(h.buttonDown)
    }
}

@Suite struct ScrollFeelTests {
    @Test func axisLockDiscardsMinorAxis() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.after(ms: 10, .move, 0, 103, 130)
        h.after(ms: 10, .move, 1, 203, 130)      // mostly vertical
        h.after(ms: 10, .move, 0, 110, 160)
        h.after(ms: 10, .move, 1, 210, 160)
        h.wait(ms: 20)                           // arbitration window passes; the scroll starts
        let totals = h.scrollTotals()
        #expect(totals.dx == 0)
        #expect(totals.dy > 50)
    }

    @Test func axisLockCanBeDisabled() {
        var cfg = GestureConfig()
        cfg.scrollAxisLock = false
        var h = Harness(config: cfg)
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.after(ms: 10, .move, 0, 110, 130)
        h.after(ms: 10, .move, 1, 210, 130)
        h.wait(ms: 50)                       // arbitration passes; tick starts the scroll
        #expect(h.scrollTotals().dx > 0)
    }

    @Test func flickProducesDecayingMomentumThenIdle() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        // 8 ms per report, 15 pt per report: about 1900 pt/s
        for k in 1...8 {
            h.after(ms: 8, .move, 0, 100, 100 + Double(k) * 15)
            h.send(.move, 1, 200, 100 + Double(k) * 15)
        }
        h.after(ms: 8, .up, 0, 100, 220)
        h.after(ms: 8, .up, 1, 200, 220)
        #expect(h.scrollPhases.contains(.ended))
        if case .momentum = h.engine.state {} else { Issue.record("expected momentum, got \(h.engine.state)") }

        h.wait(ms: 3000)
        let phases = h.scrollPhases
        #expect(phases.filter { $0 == .momentumBegan }.count == 1)
        #expect(phases.last == .momentumEnded)
        #expect(phases.filter { $0 == .momentumChanged }.count > 5)
        #expect(h.engine.state == .idle)

        // Momentum deltas shrink over time.
        let momentumDys = h.actions.compactMap { a -> Double? in
            if case .scroll(_, let dy, _, let p) = a, p == .momentumChanged { return dy } else { return nil }
        }
        #expect(momentumDys.first! > momentumDys.last!)
        #expect(momentumDys.allSatisfy { $0 > 0 })
        // Total inertial travel is meaningful but finite (v/friction ≈ 1900/4 ≈ 475 pt at most).
        let total = momentumDys.reduce(0, +)
        #expect(total > 100 && total < 600)
    }

    @Test func slowReleaseHasNoMomentum() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        for k in 1...8 {
            h.after(ms: 50, .move, 0, 100, 100 + Double(k) * 3)     // 60 pt/s
            h.send(.move, 1, 200, 100 + Double(k) * 3)
        }
        h.after(ms: 50, .up, 0, 100, 124)
        h.after(ms: 10, .up, 1, 200, 124)
        h.wait(ms: 500)
        #expect(!h.scrollPhases.contains(.momentumBegan))
        #expect(h.engine.state == .idle)
    }

    @Test func touchDuringMomentumStopsIt() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        for k in 1...8 {
            h.after(ms: 8, .move, 0, 100, 100 + Double(k) * 15)
            h.send(.move, 1, 200, 100 + Double(k) * 15)
        }
        h.after(ms: 8, .up, 0, 100, 220)
        h.after(ms: 8, .up, 1, 200, 220)
        h.wait(ms: 100)
        #expect(h.scrollPhases.contains(.momentumBegan))
        h.after(ms: 5, .down, 0, 300, 300)
        #expect(h.scrollPhases.last == .momentumEnded)
        if case .pendingOne = h.engine.state {} else { Issue.record("expected pendingOne, got \(h.engine.state)") }
        h.after(ms: 50, .up, 0, 300, 300)
        #expect(h.actions.last == .leftClick(CGPoint(x: 300, y: 300)))
    }

    @Test func momentumCanBeDisabled() {
        var cfg = GestureConfig()
        cfg.momentumEnabled = false
        var h = Harness(config: cfg)
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        for k in 1...8 {
            h.after(ms: 8, .move, 0, 100, 100 + Double(k) * 15)
            h.send(.move, 1, 200, 100 + Double(k) * 15)
        }
        h.after(ms: 8, .up, 0, 100, 220)
        h.after(ms: 8, .up, 1, 200, 220)
        h.wait(ms: 500)
        #expect(!h.scrollPhases.contains(.momentumBegan))
        #expect(h.engine.state == .idle)
    }
}

@Suite struct PinchTests {
    @Test func spreadingFingersZoomsInPerStep() {
        var h = Harness()
        h.down(0, 300, 300)
        h.down(1, 400, 300)                 // separation 100
        h.wait(ms: 50)
        h.after(ms: 10, .move, 0, 280, 300)
        h.after(ms: 10, .move, 1, 420, 300) // 140: one step
        #expect(h.systemActions == [.zoomIn])
        h.after(ms: 10, .move, 0, 240, 300)
        h.after(ms: 10, .move, 1, 460, 300) // 220: two more steps
        #expect(h.systemActions == [.zoomIn, .zoomIn, .zoomIn])
        h.after(ms: 10, .up, 0, 240, 300)
        h.after(ms: 10, .up, 1, 460, 300)
        #expect(h.engine.state == .idle)
        #expect(!h.scrollPhases.contains(.began))
    }

    @Test func closingFingersZoomsOut() {
        var h = Harness()
        h.down(0, 200, 300)
        h.down(1, 500, 300)                 // 300
        h.wait(ms: 50)
        h.after(ms: 10, .move, 0, 250, 300)
        h.after(ms: 10, .move, 1, 450, 300) // 200: two steps
        #expect(h.systemActions == [.zoomOut, .zoomOut])
    }

    @Test func pinchDoesNotStartWhenFingersMoveTogether() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.after(ms: 10, .move, 0, 100, 150)
        h.after(ms: 10, .move, 1, 200, 150)
        h.wait(ms: 50)
        #expect(h.systemActions.isEmpty)
        #expect(h.scrollPhases.first == .began)
    }

    @Test func canBeDisabled() {
        var cfg = GestureConfig()
        cfg.pinchZoomEnabled = false
        var h = Harness(config: cfg)
        h.down(0, 300, 300)
        h.down(1, 400, 300)
        h.wait(ms: 50)
        h.after(ms: 10, .move, 0, 250, 300)
        h.after(ms: 10, .move, 1, 450, 300)
        #expect(h.systemActions.isEmpty)
    }
}

/// The failure mode seen live on 2026-09-15: fingers of one hand land a frame or two apart,
/// and the first one or two are already moving before the last one touches down.
@Suite struct StaggeredLandingTests {
    @Test func firstFingerMovingBeforeOthersLandStillSwipes() {
        var h = Harness()
        h.down(0, 300, 300)
        h.after(ms: 8, .move, 0, 300, 285)          // 15 pt: past the tap threshold, inside arbitration
        h.after(ms: 8, .down, 1, 400, 300)
        h.send(.down, 2, 500, 300)
        for k in 1...5 {
            h.after(ms: 8, .move, 0, 300, 285 - Double(k) * 20)
            h.send(.move, 1, 400, 300 - Double(k) * 20)
            h.send(.move, 2, 500, 300 - Double(k) * 20)
        }
        #expect(h.systemActions == [.missionControl])
        #expect(!h.actions.contains { if case .leftDown = $0 { return true } else { return false } })
    }

    @Test func pairMovingBeforeThirdLandsStillSwipes() {
        var h = Harness()
        h.down(0, 300, 300)
        h.send(.down, 1, 400, 300)
        h.after(ms: 8, .move, 0, 300, 290)
        h.send(.move, 1, 400, 290)                  // centroid moved 10: past the dead zone, inside arbitration
        h.after(ms: 8, .move, 0, 300, 280)
        h.send(.move, 1, 400, 280)
        h.after(ms: 8, .down, 2, 500, 300)          // 24 ms after the pair landed
        for k in 1...5 {
            h.after(ms: 8, .move, 0, 300, 280 - Double(k) * 20)
            h.send(.move, 1, 400, 280 - Double(k) * 20)
            h.send(.move, 2, 500, 300 - Double(k) * 20)
        }
        #expect(h.systemActions == [.missionControl])
        #expect(!h.scrollPhases.contains(.began))
    }

    @Test func thirdFingerShortlyAfterScrollBeganConvertsToSwipe() {
        var h = Harness()
        h.down(0, 300, 300)
        h.send(.down, 1, 400, 300)
        h.wait(ms: 50)                              // arbitration over
        h.after(ms: 8, .move, 0, 300, 285)
        h.send(.move, 1, 400, 285)                  // scroll begins
        #expect(h.scrollPhases.first == .began)
        h.after(ms: 8, .down, 2, 500, 300)          // 16 ms into the scroll
        #expect(h.scrollPhases.last == .ended)
        for k in 1...5 {
            h.after(ms: 8, .move, 0, 300, 285 - Double(k) * 20)
            h.send(.move, 1, 400, 285 - Double(k) * 20)
            h.send(.move, 2, 500, 300 - Double(k) * 20)
        }
        #expect(h.systemActions == [.missionControl])
    }

    @Test func dragIsOnlyDelayedNotLost() {
        var h = Harness()
        h.down(0, 300, 300)
        h.after(ms: 8, .move, 0, 320, 300)
        h.after(ms: 8, .move, 0, 340, 300)
        #expect(h.actions.isEmpty)
        h.after(ms: 30, .move, 0, 360, 300)         // 46 ms after touchdown
        #expect(h.actions == [.leftDown(CGPoint(x: 300, y: 300)), .moveTo(CGPoint(x: 360, y: 300))])
    }
}

@Suite struct ThreeFingerTests {
    func three(_ h: inout Harness) {
        h.down(0, 300, 300)
        h.after(ms: 10, .down, 1, 400, 300)
        h.after(ms: 10, .down, 2, 500, 300)
    }

    @Test func swipeLeftGoesToNextSpace() {
        var h = Harness()
        three(&h)
        for k in 1...4 {
            h.after(ms: 10, .move, 0, 300 - Double(k) * 25, 300)
            h.send(.move, 1, 400 - Double(k) * 25, 300)
            h.send(.move, 2, 500 - Double(k) * 25, 300)
        }
        #expect(h.systemActions == [.nextSpace])
        h.up(0, 200, 300); h.up(1, 300, 300); h.up(2, 400, 300)
        #expect(h.engine.state == .idle)
        #expect(!h.buttonDown)
    }

    @Test func swipeRightGoesToPreviousSpace() {
        var h = Harness()
        three(&h)
        for k in 1...4 {
            h.after(ms: 10, .move, 0, 300 + Double(k) * 25, 300)
            h.send(.move, 1, 400 + Double(k) * 25, 300)
            h.send(.move, 2, 500 + Double(k) * 25, 300)
        }
        #expect(h.systemActions == [.previousSpace])
    }

    @Test func swipeUpIsMissionControlAndDownIsAppExpose() {
        var up = Harness()
        three(&up)
        for k in 1...4 {
            up.after(ms: 10, .move, 0, 300, 300 - Double(k) * 25)
            up.send(.move, 1, 400, 300 - Double(k) * 25)
            up.send(.move, 2, 500, 300 - Double(k) * 25)
        }
        #expect(up.systemActions == [.missionControl])

        var down = Harness()
        three(&down)
        for k in 1...4 {
            down.after(ms: 10, .move, 0, 300, 300 + Double(k) * 25)
            down.send(.move, 1, 400, 300 + Double(k) * 25)
            down.send(.move, 2, 500, 300 + Double(k) * 25)
        }
        #expect(down.systemActions == [.appExpose])
    }

    @Test func onlyOneActionPerSwipe() {
        var h = Harness()
        three(&h)
        for k in 1...12 {
            h.after(ms: 10, .move, 0, 300 - Double(k) * 30, 300)
            h.send(.move, 1, 400 - Double(k) * 30, 300)
            h.send(.move, 2, 500 - Double(k) * 30, 300)
        }
        #expect(h.systemActions.count == 1)
    }

    @Test func threeFingerTapDoesNothing() {
        var h = Harness()
        three(&h)
        h.after(ms: 50, .up, 0, 300, 300)
        h.up(1, 400, 300)
        h.up(2, 500, 300)
        #expect(h.actions.isEmpty)
        #expect(h.engine.state == .idle)
    }

    @Test func fourFingersIsAPalm() {
        var h = Harness()
        three(&h)
        h.after(ms: 10, .down, 3, 600, 300)
        for k in 1...4 {
            h.after(ms: 10, .move, 0, 300 - Double(k) * 25, 300)
        }
        #expect(h.actions.isEmpty)
        h.up(0, 200, 300); h.up(1, 400, 300); h.up(2, 500, 300); h.up(3, 600, 300)
        #expect(h.engine.state == .idle)
    }

    @Test func canBeDisabled() {
        var cfg = GestureConfig()
        cfg.threeFingerSwipeEnabled = false
        var h = Harness(config: cfg)
        three(&h)
        for k in 1...4 {
            h.after(ms: 10, .move, 0, 300 - Double(k) * 25, 300)
        }
        #expect(h.actions.isEmpty)
    }
}

@Suite struct EdgeRejectionTests {
    @Test func mapperFlagsContactsNearTheBezel() {
        let m = DisplayMapper(geometry: DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        #expect(m.isNearEdge(x: 0, y: 2000))
        #expect(m.isNearEdge(x: 4095, y: 2000))
        #expect(m.isNearEdge(x: 2000, y: 10))
        #expect(m.isNearEdge(x: 2000, y: 4090))
        #expect(!m.isNearEdge(x: 2000, y: 2000))
        #expect(!m.isNearEdge(x: 60, y: 2000))       // 1.5%: inside the margin
        var cal = Calibration()
        cal.edgeRejectFraction = 0
        #expect(!DisplayMapper(geometry: m.geometry, calibration: cal).isNearEdge(x: 0, y: 0))
    }

    @Test func edgeContactIsSwallowed() {
        var h = Harness()
        h.actions += h.engine.handle(MappedTouchEvent(kind: .down, id: 0, point: CGPoint(x: 2, y: 500), time: h.clock, nearEdge: true))
        h.move(0, 40, 500)
        h.wait(ms: 700)
        h.up(0, 40, 500)
        #expect(h.actions.isEmpty)
        #expect(h.engine.state == .idle)
    }

    @Test func edgeContactDuringTapCancelsIt() {
        var h = Harness()
        h.down(0, 300, 300)
        h.actions += h.engine.handle(MappedTouchEvent(kind: .down, id: 1, point: CGPoint(x: 1915, y: 500), time: h.clock, nearEdge: true))
        h.up(0, 300, 300)
        h.up(1, 1915, 500)
        #expect(h.actions.isEmpty)
        #expect(h.engine.state == .idle)
    }

    @Test func edgeContactDuringDragReleasesTheButton() {
        var h = Harness()
        h.down(0, 300, 300)
        h.move(0, 350, 300)
        h.wait(ms: 50)
        #expect(h.buttonDown)
        h.actions += h.engine.handle(MappedTouchEvent(kind: .down, id: 1, point: CGPoint(x: 1915, y: 500), time: h.clock, nearEdge: true))
        #expect(!h.buttonDown)
        #expect(h.actions.last == .leftUp(CGPoint(x: 350, y: 300)))
    }
}
