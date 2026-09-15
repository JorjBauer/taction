import Foundation
import CoreGraphics

/// A finger event already mapped to global screen points. Time is host monotonic seconds.
public struct MappedTouchEvent: Equatable {
    public enum Kind: Equatable { case down, move, up }
    public var kind: Kind
    public var id: UInt8
    public var point: CGPoint
    public var time: Double
    /// The raw contact lies within `Calibration.edgeRejectFraction` of the panel's edge.
    public var nearEdge: Bool

    public init(kind: Kind, id: UInt8, point: CGPoint, time: Double, nearEdge: Bool = false) {
        self.kind = kind
        self.id = id
        self.point = point
        self.time = time
        self.nearEdge = nearEdge
    }

    public init(_ event: TouchEvent, mapper: DisplayMapper) {
        let (kind, id, x, y, t): (Kind, UInt8, UInt16, UInt16, Double)
        switch event {
        case .down(let i, let px, let py, let time): (kind, id, x, y, t) = (.down, i, px, py, time)
        case .move(let i, let px, let py, let time): (kind, id, x, y, t) = (.move, i, px, py, time)
        case .up(let i, let px, let py, let time): (kind, id, x, y, t) = (.up, i, px, py, time)
        }
        self.init(kind: kind, id: id, point: mapper.point(forX: x, y: y), time: t, nearEdge: mapper.isNearEdge(x: x, y: y))
    }
}

public enum ScrollPhase: Equatable {
    case began, changed, ended
    /// Synthesized inertia after the fingers lift. Posted with the momentum phase field, not the scroll phase.
    case momentumBegan, momentumChanged, momentumEnded
}

/// System-level actions the daemon performs with keystrokes. Named by result, not by finger motion.
public enum SystemAction: Equatable {
    case previousSpace     // Ctrl+Left
    case nextSpace         // Ctrl+Right
    case missionControl    // Ctrl+Up
    case appExpose         // Ctrl+Down
    case zoomIn            // Cmd+=
    case zoomOut           // Cmd+-
}

/// What the daemon should do to the system. The engine never posts anything itself.
public enum OutputAction: Equatable {
    case moveTo(CGPoint)
    case leftDown(CGPoint)
    case leftUp(CGPoint)
    /// Down and up at once.
    case leftClick(CGPoint)
    case rightClick(CGPoint)
    /// `dx` and `dy` are content displacement in points: positive `dy` means the content
    /// should move down (the user sees earlier content), which is what fingers moving down
    /// produce under natural scrolling.
    case scroll(dx: Double, dy: Double, at: CGPoint, phase: ScrollPhase)
    case system(SystemAction)
}

public struct GestureConfig: Codable, Equatable {
    // One finger
    /// A one-finger touch shorter than this, with little movement, is a tap.
    public var tapMaxDurationMs: Double = 250
    /// Movement beyond this (points) turns a pending touch into a drag.
    public var tapMaxMovementPt: Double = 10
    /// A still one-finger press this long is a right click.
    public var longPressRightClick: Bool = true
    public var longPressMs: Double = 500
    /// Only when `longPressRightClick` is off: how long a still finger waits before committing a
    /// left mouse down, so a second finger can still turn it into a two-finger gesture.
    public var dragArbitrationMs: Double = 80
    /// Fingers of one hand land a frame or two apart. A drag, scroll, or pinch is not committed
    /// until this long after the most recent finger landed, so a late finger can still turn the
    /// gesture into a multi-finger one. Measured 2026-09-15: the second and third fingers of a
    /// three-finger swipe landed 46 ms after the first, in the same frame as each other.
    public var multiFingerArbitrationMs: Double = 40

    // Two fingers
    /// Two fingers down and up within this, with little movement, is a right click.
    public var twoFingerTapMaxDurationMs: Double = 300
    /// Two-finger centroid movement beyond this (points) starts a scroll.
    public var scrollDeadZonePt: Double = 6
    /// Multiplier on scroll deltas.
    public var scrollGain: Double = 1.0
    /// Content follows the fingers when true.
    public var naturalScrolling: Bool = true
    /// Once a scroll starts, movement on the minor axis is discarded.
    public var scrollAxisLock: Bool = true
    /// Continue scrolling after the fingers lift, decaying like a trackpad.
    public var momentumEnabled: Bool = true
    /// Release speed (points per second) below which no momentum starts.
    public var momentumMinStartSpeedPtPerSec: Double = 150
    /// Release speed is clamped to this so a noisy last sample cannot launch a runaway scroll.
    public var momentumMaxSpeedPtPerSec: Double = 3000
    /// Exponential friction per second: velocity is multiplied by exp(-friction * dt).
    public var momentumFrictionPerSec: Double = 4.0
    /// Momentum stops below this speed (points per second).
    public var momentumStopSpeedPtPerSec: Double = 20
    /// Separation change beyond this (points) starts a pinch; each further step posts one zoom keystroke.
    public var pinchZoomEnabled: Bool = true
    public var pinchStepPt: Double = 40
    /// A second contact farther than this (points) from the first is a palm, not a finger:
    /// everything is ignored until all contacts lift. On the MB16AMT at 1080p, 1 cm is about 55 pt,
    /// so 600 pt is roughly 11 cm, wide enough for a spread pinch-in. A palm measured on
    /// 2026-09-15 registered two contacts ~970 pt (17 cm) apart.
    public var twoFingerMaxSeparationPt: Double = 600

    // Three fingers
    public var threeFingerSwipeEnabled: Bool = true
    /// Centroid movement (points) that counts as a three-finger swipe.
    public var threeFingerSwipeThresholdPt: Double = 60

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? current }
        tapMaxDurationMs = d(.tapMaxDurationMs, tapMaxDurationMs)
        tapMaxMovementPt = d(.tapMaxMovementPt, tapMaxMovementPt)
        longPressRightClick = d(.longPressRightClick, longPressRightClick)
        longPressMs = d(.longPressMs, longPressMs)
        dragArbitrationMs = d(.dragArbitrationMs, dragArbitrationMs)
        multiFingerArbitrationMs = d(.multiFingerArbitrationMs, multiFingerArbitrationMs)
        twoFingerTapMaxDurationMs = d(.twoFingerTapMaxDurationMs, twoFingerTapMaxDurationMs)
        scrollDeadZonePt = d(.scrollDeadZonePt, scrollDeadZonePt)
        scrollGain = d(.scrollGain, scrollGain)
        naturalScrolling = d(.naturalScrolling, naturalScrolling)
        scrollAxisLock = d(.scrollAxisLock, scrollAxisLock)
        momentumEnabled = d(.momentumEnabled, momentumEnabled)
        momentumMinStartSpeedPtPerSec = d(.momentumMinStartSpeedPtPerSec, momentumMinStartSpeedPtPerSec)
        momentumMaxSpeedPtPerSec = d(.momentumMaxSpeedPtPerSec, momentumMaxSpeedPtPerSec)
        momentumFrictionPerSec = d(.momentumFrictionPerSec, momentumFrictionPerSec)
        momentumStopSpeedPtPerSec = d(.momentumStopSpeedPtPerSec, momentumStopSpeedPtPerSec)
        pinchZoomEnabled = d(.pinchZoomEnabled, pinchZoomEnabled)
        pinchStepPt = d(.pinchStepPt, pinchStepPt)
        twoFingerMaxSeparationPt = d(.twoFingerMaxSeparationPt, twoFingerMaxSeparationPt)
        threeFingerSwipeEnabled = d(.threeFingerSwipeEnabled, threeFingerSwipeEnabled)
        threeFingerSwipeThresholdPt = d(.threeFingerSwipeThresholdPt, threeFingerSwipeThresholdPt)
    }
}

/// The gesture state machine described in taction/03-project-kit.md.
///
/// Invariant: the left button is held only while in `.dragging`, and every transition out of
/// `.dragging` emits `leftUp`. `GestureEngineTests` checks this with random input.
public struct GestureEngine {
    public enum Axis: Equatable { case free, horizontal, vertical }

    public enum State: Equatable {
        case idle
        case pendingOne(id: UInt8, origin: CGPoint, current: CGPoint, t0: Double)
        case dragging(id: UInt8, current: CGPoint)
        case pendingTwo(a: UInt8, b: UInt8, aPos: CGPoint, bPos: CGPoint, originCentroid: CGPoint, separation0: Double, t0: Double, moved: Bool)
        /// One of two fingers lifted during a pending two-finger tap; waiting for the other.
        case pendingTwoOneLifted(remaining: UInt8, originCentroid: CGPoint, t0: Double, moved: Bool)
        case scrolling(a: UInt8, b: UInt8, aPos: CGPoint, bPos: CGPoint, lastCentroid: CGPoint, axis: Axis, startedAt: Double)
        case pinching(a: UInt8, b: UInt8, aPos: CGPoint, bPos: CGPoint, lastSeparation: Double)
        case pendingThree(ids: [UInt8], positions: [UInt8: CGPoint], originCentroid: CGPoint)
        /// Inertial scrolling after the fingers lifted. `remaining` fingers are still down but inert.
        case momentum(vx: Double, vy: Double, at: CGPoint, lastT: Double, started: Bool, remaining: Set<UInt8>)
        /// Waiting for every finger to lift before doing anything else.
        case holding(remaining: Set<UInt8>)
    }

    public private(set) var state: State = .idle
    public var config: GestureConfig
    /// Fingers that arrived at a moment where they cannot participate (finger during drag, extra finger).
    private var ignored: Set<UInt8> = []
    /// Recent (time, centroid) samples while scrolling, for the release velocity.
    private var scrollSamples: [(Double, CGPoint)] = []

    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// True while a timer transition could fire; the daemon should call `tick` every ~10 ms while set.
    public var needsTick: Bool {
        switch state {
        case .pendingOne, .pendingTwo, .pendingTwoOneLifted, .momentum: return true
        default: return false
        }
    }

    public var isLeftButtonDown: Bool {
        if case .dragging = state { return true }
        return false
    }

    // MARK: Input

    public mutating func handle(_ e: MappedTouchEvent) -> [OutputAction] {
        switch e.kind {
        case .down: return down(e)
        case .move: return move(e)
        case .up: return up(e)
        }
    }

    /// Fire time-based transitions. `now` in the same seconds clock as the events.
    public mutating func tick(now: Double) -> [OutputAction] {
        switch state {
        case .pendingOne(let id, let origin, let current, let t0):
            let moved = dist(origin, current) > config.tapMaxMovementPt
            if moved {
                // The finger already moved past the tap threshold; the drag was only waiting for
                // the multi-finger arbitration window to pass.
                if ms(now - t0) >= config.multiFingerArbitrationMs {
                    state = .dragging(id: id, current: current)
                    return [.leftDown(origin), .moveTo(current)]
                }
            } else if config.longPressRightClick {
                if ms(now - t0) > config.longPressMs {
                    state = .holding(remaining: [id])
                    return [.rightClick(origin)]
                }
            } else if ms(now - t0) > config.dragArbitrationMs {
                state = .dragging(id: id, current: origin)
                return [.leftDown(origin)]
            }
        case .pendingTwo(let a, let b, let aPos, let bPos, let originCentroid, let sep0, let t0, let moved):
            if moved, ms(now - t0) >= config.multiFingerArbitrationMs,
               let out = decideTwo(a: a, b: b, aPos: aPos, bPos: bPos, originCentroid: originCentroid, sep0: sep0, t0: t0, now: now) {
                return out
            }
            if ms(now - t0) > config.twoFingerTapMaxDurationMs && !moved {
                state = .holding(remaining: [a, b])
            }
        case .pendingTwoOneLifted(let remaining, _, let t0, _):
            if ms(now - t0) > config.twoFingerTapMaxDurationMs {
                state = .holding(remaining: [remaining])
            }
        case .momentum(let vx, let vy, let at, let lastT, let started, let remaining):
            return momentumStep(vx: vx, vy: vy, at: at, lastT: lastT, started: started, remaining: remaining, now: now)
        default:
            break
        }
        return []
    }

    /// Force back to idle, releasing anything held. Used on device removal and sleep.
    public mutating func reset() -> [OutputAction] {
        defer { state = .idle; ignored = []; scrollSamples = [] }
        switch state {
        case .dragging(_, let current): return [.leftUp(current)]
        case .scrolling(_, _, _, _, let c, _, _): return [.scroll(dx: 0, dy: 0, at: c, phase: .ended)]
        case .momentum(_, _, let at, _, let started, _): return started ? [.scroll(dx: 0, dy: 0, at: at, phase: .momentumEnded)] : []
        default: return []
        }
    }

    // MARK: Down

    private mutating func down(_ e: MappedTouchEvent) -> [OutputAction] {
        // A contact starting on the bezel is a palm or a gripping hand. Swallow it and anything
        // else until every contact lifts.
        if e.nearEdge { return palm(adding: e.id) }

        switch state {
        case .idle:
            ignored = []
            state = .pendingOne(id: e.id, origin: e.point, current: e.point, t0: e.time)
            // Deliberately no moveTo here: the click or drag-start that follows carries its own
            // position, and a palm (second contact in the same frame) must not move the pointer.
            return []

        case .pendingOne(let a, _, let current, _):
            if dist(current, e.point) > config.twoFingerMaxSeparationPt { return palm(adding: e.id) }
            let centroid = mid(current, e.point)
            state = .pendingTwo(a: a, b: e.id, aPos: current, bPos: e.point, originCentroid: centroid,
                                separation0: dist(current, e.point), t0: e.time, moved: false)
            return []

        case .pendingTwo(let a, let b, let aPos, let bPos, _, _, _, _):
            let c2 = mid(aPos, bPos)
            guard config.threeFingerSwipeEnabled, dist(c2, e.point) <= config.twoFingerMaxSeparationPt else {
                return palm(adding: e.id)
            }
            let positions: [UInt8: CGPoint] = [a: aPos, b: bPos, e.id: e.point]
            state = .pendingThree(ids: [a, b, e.id], positions: positions, originCentroid: centroid(of: positions))
            return []

        case .pendingThree:
            // Four contacts: nobody swipes with four fingers on a 15 inch panel. Palm.
            return palm(adding: e.id)

        case .scrolling(let a, let b, let aPos, let bPos, let last, _, let startedAt):
            // A third finger landing right after a scroll began means the pair simply moved
            // before the third finger touched down: reinterpret as a three-finger gesture.
            if config.threeFingerSwipeEnabled, e.time - startedAt <= 0.1, dist(mid(aPos, bPos), e.point) <= config.twoFingerMaxSeparationPt {
                let positions: [UInt8: CGPoint] = [a: aPos, b: bPos, e.id: e.point]
                state = .pendingThree(ids: [a, b, e.id], positions: positions, originCentroid: centroid(of: positions))
                scrollSamples = []
                return [.scroll(dx: 0, dy: 0, at: last, phase: .ended)]
            }
            ignored.insert(e.id)
            return []

        case .dragging, .pinching:
            ignored.insert(e.id)
            return []

        case .pendingTwoOneLifted(let remaining, _, _, _):
            state = .holding(remaining: [remaining, e.id])
            return []

        case .momentum(_, _, let at, _, let started, let remaining):
            // A touch during inertia stops it, like putting a finger on a trackpad.
            var out: [OutputAction] = started ? [.scroll(dx: 0, dy: 0, at: at, phase: .momentumEnded)] : []
            if remaining.isEmpty {
                state = .idle
                out += down(e)
            } else {
                state = .holding(remaining: remaining.union([e.id]))
            }
            return out

        case .holding(var remaining):
            remaining.insert(e.id)
            state = .holding(remaining: remaining)
            return []
        }
    }

    /// Treat the current situation as a palm: cancel whatever was pending and wait for all contacts to lift.
    private mutating func palm(adding id: UInt8) -> [OutputAction] {
        var out: [OutputAction] = []
        var fingers: Set<UInt8> = [id]
        switch state {
        case .idle: break
        case .pendingOne(let a, _, _, _): fingers.insert(a)
        case .dragging(let a, let current): fingers.insert(a); out.append(.leftUp(current))
        case .pendingTwo(let a, let b, _, _, _, _, _, _): fingers.formUnion([a, b])
        case .pendingTwoOneLifted(let r, _, _, _): fingers.insert(r)
        case .scrolling(let a, let b, _, _, let c, _, _): fingers.formUnion([a, b]); out.append(.scroll(dx: 0, dy: 0, at: c, phase: .ended))
        case .pinching(let a, let b, _, _, _): fingers.formUnion([a, b])
        case .pendingThree(let ids, _, _): fingers.formUnion(ids)
        case .momentum(_, _, let at, _, let started, let remaining):
            fingers.formUnion(remaining)
            if started { out.append(.scroll(dx: 0, dy: 0, at: at, phase: .momentumEnded)) }
        case .holding(let remaining): fingers.formUnion(remaining)
        }
        fingers.formUnion(ignored)
        ignored = []
        scrollSamples = []
        state = .holding(remaining: fingers)
        return out
    }

    // MARK: Move

    private mutating func move(_ e: MappedTouchEvent) -> [OutputAction] {
        if ignored.contains(e.id) { return [] }
        switch state {
        case .idle, .holding, .momentum:
            return []

        case .pendingOne(let id, let origin, _, let t0):
            guard e.id == id else { return [] }
            if dist(origin, e.point) > config.tapMaxMovementPt {
                // Commit the drag only once the other fingers of a multi-finger gesture have had
                // their chance to land; until then keep tracking.
                if ms(e.time - t0) >= config.multiFingerArbitrationMs {
                    state = .dragging(id: id, current: e.point)
                    return [.leftDown(origin), .moveTo(e.point)]
                }
                state = .pendingOne(id: id, origin: origin, current: e.point, t0: t0)
                return []
            }
            // Timers normally fire from tick(); check here too so a late tick cannot miss the long press.
            if config.longPressRightClick && ms(e.time - t0) > config.longPressMs {
                state = .holding(remaining: [id])
                return [.rightClick(origin)]
            }
            state = .pendingOne(id: id, origin: origin, current: e.point, t0: t0)
            return []

        case .dragging(let id, _):
            guard e.id == id else { return [] }
            state = .dragging(id: id, current: e.point)
            return [.moveTo(e.point)]

        case .pendingTwo(let a, let b, var aPos, var bPos, let originCentroid, let sep0, let t0, let moved):
            if e.id == a { aPos = e.point } else if e.id == b { bPos = e.point } else { return [] }
            let c = mid(aPos, bPos)
            let dc = dist(originCentroid, c)
            let ds = abs(dist(aPos, bPos) - sep0)
            let nowMoved = moved || dc > config.tapMaxMovementPt || ds > config.tapMaxMovementPt
            state = .pendingTwo(a: a, b: b, aPos: aPos, bPos: bPos, originCentroid: originCentroid, separation0: sep0, t0: t0, moved: nowMoved)
            // Wait out the arbitration window so a third finger can still join; tick() retries after it.
            if ms(e.time - t0) >= config.multiFingerArbitrationMs,
               let out = decideTwo(a: a, b: b, aPos: aPos, bPos: bPos, originCentroid: originCentroid, sep0: sep0, t0: t0, now: e.time) {
                return out
            }
            return []

        case .pendingTwoOneLifted(let remaining, let originCentroid, let t0, let moved):
            guard e.id == remaining else { return [] }
            // If the remaining finger wanders, it is no longer a tap. Do not degrade into a drag.
            if dist(originCentroid, e.point) > config.tapMaxMovementPt * 2 {
                state = .holding(remaining: [remaining])
            } else {
                state = .pendingTwoOneLifted(remaining: remaining, originCentroid: originCentroid, t0: t0, moved: moved)
            }
            return []

        case .scrolling(let a, let b, var aPos, var bPos, let last, let axis, let startedAt):
            if e.id == a { aPos = e.point } else if e.id == b { bPos = e.point } else { return [] }
            let c = mid(aPos, bPos)
            state = .scrolling(a: a, b: b, aPos: aPos, bPos: bPos, lastCentroid: c, axis: axis, startedAt: startedAt)
            scrollSamples.append((e.time, c))
            if scrollSamples.count > 16 { scrollSamples.removeFirst(scrollSamples.count - 16) }
            let (dx, dy) = scrollDelta(from: last, to: c, axis: axis)
            if dx == 0 && dy == 0 { return [] }
            return [.scroll(dx: dx, dy: dy, at: c, phase: .changed)]

        case .pinching(let a, let b, var aPos, var bPos, var last):
            if e.id == a { aPos = e.point } else if e.id == b { bPos = e.point } else { return [] }
            let sep = dist(aPos, bPos)
            var out: [OutputAction] = []
            while abs(sep - last) >= config.pinchStepPt {
                out.append(.system(sep > last ? .zoomIn : .zoomOut))
                last += sep > last ? config.pinchStepPt : -config.pinchStepPt
            }
            state = .pinching(a: a, b: b, aPos: aPos, bPos: bPos, lastSeparation: last)
            return out

        case .pendingThree(let ids, var positions, let origin):
            guard positions[e.id] != nil else { return [] }
            positions[e.id] = e.point
            let c = centroid(of: positions)
            let dx = c.x - origin.x, dy = c.y - origin.y
            if hypot(dx, dy) > config.threeFingerSwipeThresholdPt {
                state = .holding(remaining: Set(ids))
                let action: SystemAction
                if abs(dx) >= abs(dy) {
                    // Fingers moving left reveal the space to the right, as on a trackpad.
                    action = dx < 0 ? .nextSpace : .previousSpace
                } else {
                    action = dy < 0 ? .missionControl : .appExpose
                }
                return [.system(action)]
            }
            state = .pendingThree(ids: ids, positions: positions, originCentroid: origin)
            return []
        }
    }

    // MARK: Up

    private mutating func up(_ e: MappedTouchEvent) -> [OutputAction] {
        if ignored.remove(e.id) != nil { return [] }
        switch state {
        case .idle:
            return []

        case .pendingOne(let id, let origin, _, let t0):
            guard e.id == id else { return [] }
            state = .idle
            if ms(e.time - t0) <= config.tapMaxDurationMs {
                return [.leftClick(origin)]
            }
            if config.longPressRightClick && ms(e.time - t0) > config.longPressMs {
                // The tick that should have fired the long press was late; honor it now.
                return [.rightClick(origin)]
            }
            // A slow, still press that ended before the long-press timer: a real down and up.
            return [.leftDown(origin), .leftUp(e.point)]

        case .dragging(let id, _):
            guard e.id == id else { return [] }
            state = .idle
            return [.leftUp(e.point)]

        case .pendingTwo(let a, let b, _, _, let originCentroid, _, let t0, let moved):
            guard e.id == a || e.id == b else { return [] }
            let remaining = e.id == a ? b : a
            state = .pendingTwoOneLifted(remaining: remaining, originCentroid: originCentroid, t0: t0, moved: moved)
            return []

        case .pendingTwoOneLifted(let remaining, let originCentroid, let t0, let moved):
            guard e.id == remaining else { return [] }
            state = .idle
            if !moved && ms(e.time - t0) <= config.twoFingerTapMaxDurationMs {
                return [.rightClick(originCentroid)]
            }
            return []

        case .scrolling(let a, let b, _, _, let last, let axis, _):
            guard e.id == a || e.id == b else { return [] }
            let remaining: Set<UInt8> = [e.id == a ? b : a]
            let out: [OutputAction] = [.scroll(dx: 0, dy: 0, at: last, phase: .ended)]
            if let (vx, vy) = releaseVelocity(axis: axis, now: e.time) {
                state = .momentum(vx: vx, vy: vy, at: last, lastT: e.time, started: false, remaining: remaining)
            } else {
                state = .holding(remaining: remaining)
            }
            scrollSamples = []
            return out

        case .pinching(let a, let b, _, _, _):
            guard e.id == a || e.id == b else { return [] }
            state = .holding(remaining: [e.id == a ? b : a])
            return []

        case .pendingThree(let ids, _, _):
            guard ids.contains(e.id) else { return [] }
            // Three fingers lifted without swiping: nothing.
            state = .holding(remaining: Set(ids).subtracting([e.id]))
            return []

        case .momentum(let vx, let vy, let at, let lastT, let started, var remaining):
            remaining.remove(e.id)
            state = .momentum(vx: vx, vy: vy, at: at, lastT: lastT, started: started, remaining: remaining)
            return []

        case .holding(var remaining):
            remaining.remove(e.id)
            state = remaining.isEmpty ? .idle : .holding(remaining: remaining)
            return []
        }
    }

    // MARK: Two-finger decision

    /// Decide whether a pending pair has become a pinch or a scroll. Returns nil to keep waiting.
    /// Called from `move` and from `tick`, both only after the arbitration window has passed.
    private mutating func decideTwo(a: UInt8, b: UInt8, aPos: CGPoint, bPos: CGPoint, originCentroid: CGPoint,
                                    sep0: Double, t0: Double, now: Double) -> [OutputAction]? {
        let c = mid(aPos, bPos)
        let dc = dist(originCentroid, c)
        let sep = dist(aPos, bPos)
        let ds = abs(sep - sep0)

        if config.pinchZoomEnabled && ds >= config.pinchStepPt && ds > dc {
            // Fingers moving apart or together more than they move as a pair: a pinch.
            var last = sep0
            var out: [OutputAction] = []
            while abs(sep - last) >= config.pinchStepPt {
                out.append(.system(sep > last ? .zoomIn : .zoomOut))
                last += sep > last ? config.pinchStepPt : -config.pinchStepPt
            }
            state = .pinching(a: a, b: b, aPos: aPos, bPos: bPos, lastSeparation: last)
            return out
        }
        // Contacts arrive one event at a time even when they moved in the same frame, so a
        // symmetric pinch transiently shifts the centroid by half a step. Requiring the pair
        // motion to exceed the separation change keeps that from starting a scroll.
        if dc > config.scrollDeadZonePt && (!config.pinchZoomEnabled || dc >= ds) {
            let delta = CGPoint(x: c.x - originCentroid.x, y: c.y - originCentroid.y)
            let axis: Axis = config.scrollAxisLock ? (abs(delta.y) >= abs(delta.x) ? .vertical : .horizontal) : .free
            state = .scrolling(a: a, b: b, aPos: aPos, bPos: bPos, lastCentroid: c, axis: axis, startedAt: now)
            scrollSamples = [(t0, originCentroid), (now, c)]
            let (dx, dy) = scrollDelta(from: originCentroid, to: c, axis: axis)
            return [.scroll(dx: dx, dy: dy, at: c, phase: .began)]
        }
        return nil
    }

    // MARK: Momentum

    /// Velocity in content-displacement points per second at release, or nil if too slow or unmeasurable.
    private func releaseVelocity(axis: Axis, now: Double) -> (Double, Double)? {
        guard config.momentumEnabled, scrollSamples.count >= 2 else { return nil }
        let window = 0.08
        let recent = scrollSamples.filter { now - $0.0 <= window }
        let first = recent.count >= 2 ? recent[0] : scrollSamples[scrollSamples.count - 2]
        let last = scrollSamples[scrollSamples.count - 1]
        let dt = last.0 - first.0
        guard dt >= 0.004 else { return nil }
        let (dx, dy) = scrollDelta(from: first.1, to: last.1, axis: axis)
        var vx = dx / dt, vy = dy / dt
        let speed = hypot(vx, vy)
        guard speed >= config.momentumMinStartSpeedPtPerSec else { return nil }
        if speed > config.momentumMaxSpeedPtPerSec {
            let s = config.momentumMaxSpeedPtPerSec / speed
            vx *= s
            vy *= s
        }
        return (vx, vy)
    }

    private mutating func momentumStep(vx: Double, vy: Double, at: CGPoint, lastT: Double, started: Bool, remaining: Set<UInt8>, now: Double) -> [OutputAction] {
        let dt = max(now - lastT, 0)
        guard dt > 0 else { return [] }
        let decay = exp(-config.momentumFrictionPerSec * dt)
        let nvx = vx * decay, nvy = vy * decay
        // Displacement over the step, integrating the exponential decay.
        let k = config.momentumFrictionPerSec > 0 ? (1 - decay) / config.momentumFrictionPerSec : dt
        let dx = vx * k, dy = vy * k
        if hypot(nvx, nvy) < config.momentumStopSpeedPtPerSec {
            state = remaining.isEmpty ? .idle : .holding(remaining: remaining)
            return started ? [.scroll(dx: dx, dy: dy, at: at, phase: .momentumChanged), .scroll(dx: 0, dy: 0, at: at, phase: .momentumEnded)] : []
        }
        state = .momentum(vx: nvx, vy: nvy, at: at, lastT: now, started: true, remaining: remaining)
        return [.scroll(dx: dx, dy: dy, at: at, phase: started ? .momentumChanged : .momentumBegan)]
    }

    // MARK: Helpers

    private func scrollDelta(from a: CGPoint, to b: CGPoint, axis: Axis) -> (Double, Double) {
        let sign: Double = config.naturalScrolling ? 1 : -1
        var dx = (b.x - a.x) * config.scrollGain * sign
        var dy = (b.y - a.y) * config.scrollGain * sign
        switch axis {
        case .vertical: dx = 0
        case .horizontal: dy = 0
        case .free: break
        }
        return (dx, dy)
    }

    private func centroid(of positions: [UInt8: CGPoint]) -> CGPoint {
        let n = Double(max(positions.count, 1))
        let sx = positions.values.reduce(0.0) { $0 + $1.x }
        let sy = positions.values.reduce(0.0) { $0 + $1.y }
        return CGPoint(x: sx / n, y: sy / n)
    }

    private func ms(_ seconds: Double) -> Double { seconds * 1000 }
    private func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}
