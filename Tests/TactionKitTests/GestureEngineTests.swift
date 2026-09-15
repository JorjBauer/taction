import Testing
import CoreGraphics
@testable import TactionKit

/// Drives the engine with screen-space events and steps its timers the way the daemon does.
struct Harness {
    var engine: GestureEngine
    var clock: Double = 10.0
    var actions: [OutputAction] = []

    init(config: GestureConfig = GestureConfig()) {
        engine = GestureEngine(config: config)
    }

    mutating func down(_ id: UInt8, _ x: Double, _ y: Double) { send(.down, id, x, y) }
    mutating func move(_ id: UInt8, _ x: Double, _ y: Double) { send(.move, id, x, y) }
    mutating func up(_ id: UInt8, _ x: Double, _ y: Double) { send(.up, id, x, y) }

    mutating func send(_ kind: MappedTouchEvent.Kind, _ id: UInt8, _ x: Double, _ y: Double) {
        actions += engine.handle(MappedTouchEvent(kind: kind, id: id, point: CGPoint(x: x, y: y), time: clock))
    }

    /// Advance time in 10 ms steps, ticking the engine each step.
    mutating func wait(ms: Double) {
        let steps = Int((ms / 10).rounded(.up))
        for _ in 0..<steps {
            clock += 0.010
            actions += engine.tick(now: clock)
        }
    }

    var buttonDown: Bool { engine.isLeftButtonDown }
}

@Suite struct GestureEngineTests {
    @Test func quickTapIsALeftClick() {
        var h = Harness()
        h.down(0, 100, 100)
        h.wait(ms: 50)
        h.move(0, 102, 101)
        h.up(0, 102, 101)
        #expect(h.actions == [.leftClick(CGPoint(x: 100, y: 100))])
        #expect(h.engine.state == .idle)
    }

    @Test func slowStillPressIsARealDownAndUp() {
        var h = Harness()
        h.down(0, 100, 100)
        h.wait(ms: 400)                 // longer than a tap, shorter than a long press
        h.up(0, 100, 100)
        #expect(h.actions == [.leftDown(CGPoint(x: 100, y: 100)), .leftUp(CGPoint(x: 100, y: 100))])
        #expect(!h.buttonDown)
    }

    @Test func arbitrationModeCommitsDragWhenLongPressIsOff() {
        var cfg = GestureConfig()
        cfg.longPressRightClick = false
        var h = Harness(config: cfg)
        h.down(0, 100, 100)
        h.wait(ms: 100)                 // past dragArbitrationMs
        #expect(h.actions == [.leftDown(CGPoint(x: 100, y: 100))])
        #expect(h.buttonDown)
        h.up(0, 100, 100)
        #expect(h.actions.last == .leftUp(CGPoint(x: 100, y: 100)))
    }

    @Test func movementCommitsDragAfterArbitrationWindow() {
        var h = Harness()
        h.down(0, 100, 100)
        h.move(0, 130, 100)
        #expect(h.actions.isEmpty, "the drag waits for possible extra fingers")
        h.wait(ms: 50)
        #expect(h.actions == [.leftDown(CGPoint(x: 100, y: 100)), .moveTo(CGPoint(x: 130, y: 100))])
        #expect(h.buttonDown)
        h.move(0, 160, 120)
        h.up(0, 170, 120)
        #expect(h.actions.suffix(2) == [.moveTo(CGPoint(x: 160, y: 120)), .leftUp(CGPoint(x: 170, y: 120))])
        #expect(!h.buttonDown)
        #expect(h.engine.state == .idle)
    }

    @Test func twoFingerTapIsARightClickAtTheCentroid() {
        var h = Harness()
        h.down(0, 100, 100)
        h.wait(ms: 20)
        h.down(1, 200, 100)
        h.wait(ms: 100)
        h.up(0, 100, 100)
        h.up(1, 200, 100)
        #expect(h.actions == [.rightClick(CGPoint(x: 150, y: 100))])
        #expect(h.engine.state == .idle)
    }

    @Test func twoFingerTapLiftingInTheOtherOrder() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.wait(ms: 50)
        h.up(1, 200, 100)
        h.up(0, 100, 100)
        #expect(h.actions.last == .rightClick(CGPoint(x: 150, y: 100)))
    }

    @Test func twoFingerHoldTooLongIsNothing() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.wait(ms: 500)
        h.up(0, 100, 100)
        h.up(1, 200, 100)
        #expect(h.actions == [])
        #expect(h.engine.state == .idle)
    }

    @Test func twoFingerDragScrollsAndNeverPressesTheButton() {
        var h = Harness()
        h.down(0, 100, 100)
        h.wait(ms: 10)
        h.down(1, 200, 100)
        h.wait(ms: 50)          // past the multi-finger arbitration window
        h.move(0, 100, 120)
        h.move(1, 200, 120)     // centroid moved 20 down: past the dead zone
        h.move(0, 100, 130)
        h.move(1, 200, 130)
        h.up(0, 100, 130)
        h.up(1, 200, 130)

        let scrolls = h.actions.compactMap { a -> (Double, Double, ScrollPhase)? in
            if case .scroll(let dx, let dy, _, let phase) = a { return (dx, dy, phase) } else { return nil }
        }
        #expect(scrolls.first?.2 == .began)
        #expect(scrolls.contains { $0.2 == .ended })
        // Natural scrolling: fingers moved down 30 in total, content displacement sums to +30.
        let totalDy = scrolls.reduce(0.0) { $0 + $1.1 }
        #expect(abs(totalDy - 30) < 0.001)
        #expect(!h.actions.contains { if case .leftDown = $0 { return true } else { return false } })
        #expect(!h.actions.contains { if case .rightClick = $0 { return true } else { return false } })
        h.wait(ms: 3000)                // let any momentum from the quick release decay
        #expect(h.engine.state == .idle)
    }

    @Test func invertedScrollingFlipsSign() {
        var cfg = GestureConfig()
        cfg.naturalScrolling = false
        var h = Harness(config: cfg)
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.wait(ms: 50)
        h.move(0, 100, 140)
        h.move(1, 200, 140)
        let dy = h.actions.compactMap { a -> Double? in if case .scroll(_, let dy, _, _) = a { return dy } else { return nil } }.reduce(0, +)
        #expect(dy < 0)
    }

    @Test func secondFingerDuringDragIsIgnored() {
        var h = Harness()
        h.down(0, 100, 100)
        h.move(0, 150, 100)
        h.wait(ms: 50)                  // drag committed
        h.down(1, 300, 300)
        h.move(1, 320, 300)
        h.up(1, 320, 300)
        h.move(0, 170, 100)
        h.up(0, 170, 100)
        #expect(h.actions == [
            .leftDown(CGPoint(x: 100, y: 100)),
            .moveTo(CGPoint(x: 150, y: 100)),
            .moveTo(CGPoint(x: 170, y: 100)),
            .leftUp(CGPoint(x: 170, y: 100)),
        ])
    }

    @Test func lateSecondFingerStillMakesATwoFingerTap() {
        // With long press on, a still finger stays pending, so a slow second finger still counts.
        var h = Harness()
        h.down(0, 100, 100)
        h.wait(ms: 200)
        h.down(1, 200, 100)
        h.up(1, 200, 100)
        h.up(0, 100, 100)
        #expect(h.actions == [.rightClick(CGPoint(x: 150, y: 100))])
    }

    @Test func lateSecondFingerIsIgnoredOnceDragging() {
        var cfg = GestureConfig()
        cfg.longPressRightClick = false
        var h = Harness(config: cfg)
        h.down(0, 100, 100)
        h.wait(ms: 200)                 // arbitration passed: dragging
        h.down(1, 200, 100)
        h.up(1, 200, 100)
        h.up(0, 100, 100)
        #expect(h.actions == [.leftDown(CGPoint(x: 100, y: 100)), .leftUp(CGPoint(x: 100, y: 100))])
    }

    @Test func oneFingerLiftedThenWanderingIsNotAClick() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.up(0, 100, 100)
        h.move(1, 260, 100)             // remaining finger wanders far
        h.up(1, 260, 100)
        #expect(h.actions == [])
        #expect(h.engine.state == .idle)
    }

    @Test func thirdFingerLongAfterScrollStartIsIgnored() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 200, 100)
        h.wait(ms: 50)
        h.move(0, 100, 150)
        h.move(1, 200, 150)             // scrolling
        h.wait(ms: 200)                 // well past the conversion window
        h.down(2, 400, 400)
        h.move(2, 400, 450)
        h.up(2, 400, 450)
        h.up(0, 100, 150)
        h.up(1, 200, 150)
        #expect(!h.actions.contains { if case .system = $0 { return true } else { return false } })
        #expect(h.engine.state == .idle)
        #expect(!h.buttonDown)
    }

    @Test func resetReleasesHeldButton() {
        var h = Harness()
        h.down(0, 100, 100)
        h.move(0, 150, 100)
        h.wait(ms: 50)
        #expect(h.buttonDown)
        let released = h.engine.reset()
        #expect(released == [.leftUp(CGPoint(x: 150, y: 100))])
        #expect(h.engine.state == .idle)
    }

    /// Random input never leaves the button held once every finger is up, and leftDown/leftUp always pair.
    @Test func randomSequencesNeverStrandTheButton() {
        var rng = SplitMix64(seed: 0x5EED)
        for round in 0..<300 {
            var h = Harness()
            var down: Set<UInt8> = []
            let steps = Int(rng.next() % 40) + 5
            for _ in 0..<steps {
                let roll = rng.next() % 10
                let id = UInt8(rng.next() % 3)
                let x = Double(rng.next() % 800), y = Double(rng.next() % 600)
                if roll < 3 && !down.contains(id) { h.down(id, x, y); down.insert(id) }
                else if roll < 6 && down.contains(id) { h.move(id, x, y) }
                else if roll < 8 && down.contains(id) { h.up(id, x, y); down.remove(id) }
                else { h.wait(ms: Double(rng.next() % 40) * 10) }
            }
            for id in down.sorted() { h.up(id, 10, 10) }
            h.wait(ms: 3000)            // long enough for any momentum to decay
            #expect(!h.buttonDown, "round \(round) left the button down; state \(h.engine.state)")
            #expect(h.engine.state == .idle, "round \(round) did not return to idle: \(h.engine.state)")
            let downs = h.actions.filter { if case .leftDown = $0 { return true } else { return false } }.count
            let ups = h.actions.filter { if case .leftUp = $0 { return true } else { return false } }.count
            #expect(downs == ups, "round \(round): \(downs) leftDown vs \(ups) leftUp")
        }
    }
}

/// Small deterministic PRNG so the property test is reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
