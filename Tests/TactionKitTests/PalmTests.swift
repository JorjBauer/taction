import Testing
import CoreGraphics
@testable import TactionKit

@Suite struct PalmTests {
    @Test func farApartSecondContactCancelsEverything() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 900, 700)            // ~1000 pt away: a palm, not a finger
        h.move(0, 100, 150)
        h.move(1, 900, 760)
        h.wait(ms: 300)
        h.up(0, 100, 150)
        h.up(1, 900, 760)
        #expect(h.actions == [])
        #expect(h.engine.state == .idle)
        #expect(!h.buttonDown)
    }

    @Test func closeSecondContactStillGestures() {
        var h = Harness()
        h.down(0, 100, 100)
        h.down(1, 300, 100)            // 200 pt: two fingers
        h.up(0, 100, 100)
        h.up(1, 300, 100)
        #expect(h.actions.last == .rightClick(CGPoint(x: 200, y: 100)))
    }

    @Test func thresholdIsConfigurable() {
        var cfg = GestureConfig()
        cfg.twoFingerMaxSeparationPt = 150
        var h = Harness(config: cfg)
        h.down(0, 100, 100)
        h.down(1, 300, 100)            // 200 pt: over the tightened limit
        h.up(0, 100, 100)
        h.up(1, 300, 100)
        #expect(h.actions == [])
    }
}
