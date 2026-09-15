import Foundation
import CoreGraphics

/// Parser, tracker, mapper, and engine wired together. The daemon and the replay tool both
/// use this so they cannot drift apart. Still side-effect free: it returns actions.
public struct Pipeline {
    public var tracker = ContactTracker()
    public var mapper: DisplayMapper
    public var engine: GestureEngine
    public private(set) var parseErrors = 0
    public private(set) var framesSeen = 0

    public init(mapper: DisplayMapper, gestures: GestureConfig = GestureConfig()) {
        self.mapper = mapper
        self.engine = GestureEngine(config: gestures)
    }

    /// Feed one raw report that arrived at host time `t` (seconds).
    public mutating func ingest(report bytes: [UInt8], at t: Double) -> (frame: Frame?, touches: [TouchEvent], actions: [OutputAction]) {
        let frame: Frame
        do {
            frame = try ReportParser.parse(bytes)
        } catch {
            parseErrors += 1
            return (nil, [], [])
        }
        framesSeen += 1
        let touches = tracker.ingest(frame, at: t)
        var actions: [OutputAction] = []
        for te in touches {
            actions += engine.handle(MappedTouchEvent(te, mapper: mapper))
        }
        return (frame, touches, actions)
    }

    /// Timer entry point; call every ~10 ms while `engine.needsTick`.
    public mutating func tick(now: Double) -> [OutputAction] {
        engine.tick(now: now)
    }

    /// Lift every finger and release anything held. Used on unplug, sleep, and stale contacts.
    ///
    /// The engine is reset first so that the synthesized lifts, which carry a much later
    /// timestamp than the last real report, cannot be mistaken for a long press or a slow tap.
    /// Only releases (left up, scroll ended) are ever emitted from here, never clicks.
    public mutating func releaseAll(at t: Double) -> [OutputAction] {
        let actions = engine.reset()
        _ = tracker.releaseAll(at: t)
        return actions
    }
}
