import Foundation
import CoreGraphics

/// Human-readable rendering shared by the probe, the replay tool, and debug logging.
public enum Formatting {
    public static func hex(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: separator)
    }

    public static func describe(_ frame: Frame) -> String {
        let slots = frame.contacts.map { c in
            "\(c.tip ? "T" : "u")\(c.id)@(\(c.x),\(c.y))"
        }.joined(separator: " ")
        return "count=\(frame.contactCount) scan=\(frame.scanTime) [\(slots)]"
    }

    public static func describe(_ e: TouchEvent) -> String {
        switch e {
        case .down(let id, let x, let y, _): return "down \(id) (\(x),\(y))"
        case .move(let id, let x, let y, _): return "move \(id) (\(x),\(y))"
        case .up(let id, let x, let y, _): return "up   \(id) (\(x),\(y))"
        }
    }

    public static func describe(_ a: OutputAction) -> String {
        func p(_ pt: CGPoint) -> String { String(format: "(%.1f,%.1f)", pt.x, pt.y) }
        switch a {
        case .moveTo(let pt): return "moveTo \(p(pt))"
        case .leftDown(let pt): return "leftDown \(p(pt))"
        case .leftUp(let pt): return "leftUp \(p(pt))"
        case .leftClick(let pt): return "leftClick \(p(pt))"
        case .rightClick(let pt): return "rightClick \(p(pt))"
        case .scroll(let dx, let dy, let at, let phase):
            return String(format: "scroll %@ dx=%.1f dy=%.1f at %@", "\(phase)", dx, dy, p(at))
        case .system(let s):
            return "system \(s)"
        }
    }

    public static func describe(_ s: GestureEngine.State) -> String {
        switch s {
        case .idle: return "idle"
        case .pendingOne(let id, _, _, _): return "pendingOne(\(id))"
        case .dragging(let id, _): return "dragging(\(id))"
        case .pendingTwo(let a, let b, _, _, _, _, _, _): return "pendingTwo(\(a),\(b))"
        case .pendingTwoOneLifted(let r, _, _, _): return "pendingTwoOneLifted(\(r))"
        case .scrolling(let a, let b, _, _, _, let axis, _): return "scrolling(\(a),\(b),\(axis))"
        case .pinching(let a, let b, _, _, _): return "pinching(\(a),\(b))"
        case .pendingThree(let ids, _, _): return "pendingThree(\(ids))"
        case .momentum(let vx, let vy, _, _, _, let r): return String(format: "momentum(v=%.0f,%.0f remaining=%@)", vx, vy, "\(r.sorted())")
        case .holding(let r): return "holding(\(r.sorted()))"
        }
    }
}
