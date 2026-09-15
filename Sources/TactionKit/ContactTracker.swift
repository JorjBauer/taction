import Foundation

/// A finger event in raw panel coordinates, stamped with host monotonic time in seconds.
public enum TouchEvent: Equatable {
    case down(id: UInt8, x: UInt16, y: UInt16, t: Double)
    case move(id: UInt8, x: UInt16, y: UInt16, t: Double)
    case up(id: UInt8, x: UInt16, y: UInt16, t: Double)

    public var id: UInt8 {
        switch self {
        case .down(let id, _, _, _), .move(let id, _, _, _), .up(let id, _, _, _): return id
        }
    }
}

/// Turns frames into down, move, and up events keyed by Contact Identifier.
///
/// Handles three firmware behaviors:
/// - liftoff reported as a slot with tip 0;
/// - liftoff reported by the contact simply vanishing from the next complete frame;
/// - hybrid frames, where a frame with more than five contacts continues in following
///   reports that carry Contact Count 0 and the same Scan Time.
public struct ContactTracker {
    private var active: [UInt8: Contact] = [:]
    private var seenThisScan: Set<UInt8> = []
    private var lastScanTime: UInt32?
    /// True when the current scan had more contacts than fit in one report, so
    /// "vanished" detection must wait for the next scan.
    private var scanIncomplete = false
    /// Host time of the most recent ingested frame.
    public private(set) var lastFrameTime: Double?

    public init() {}

    public var activeCount: Int { active.count }
    public var activeIDs: [UInt8] { active.keys.sorted() }

    public mutating func ingest(_ frame: Frame, at t: Double) -> [TouchEvent] {
        var events: [TouchEvent] = []
        lastFrameTime = t

        let isContinuation = frame.contactCount == 0
            && !frame.contacts.isEmpty
            && lastScanTime == frame.scanTime
            && scanIncomplete

        if !isContinuation {
            // A new scan begins. If the previous one was incomplete, contacts it never mentioned have lifted.
            if scanIncomplete {
                for id in active.keys.sorted() where !seenThisScan.contains(id) {
                    let c = active.removeValue(forKey: id)!
                    events.append(.up(id: id, x: c.x, y: c.y, t: t))
                }
            }
            seenThisScan = []
        }

        for c in frame.contacts {
            seenThisScan.insert(c.id)
            if c.tip {
                if active[c.id] == nil {
                    events.append(.down(id: c.id, x: c.x, y: c.y, t: t))
                } else {
                    events.append(.move(id: c.id, x: c.x, y: c.y, t: t))
                }
                active[c.id] = c
            } else if active[c.id] != nil {
                active.removeValue(forKey: c.id)
                events.append(.up(id: c.id, x: c.x, y: c.y, t: t))
            }
        }

        if isContinuation {
            // Still cannot know whether more reports follow; leave scanIncomplete set.
        } else if frame.contactCount <= ReportLayout.maxContactsPerReport {
            // Complete frame: anything active that this frame did not mention has lifted.
            // A frame with Contact Count 0 and no contacts is the firmware's "all up".
            for id in active.keys.sorted() where !seenThisScan.contains(id) {
                let c = active.removeValue(forKey: id)!
                events.append(.up(id: id, x: c.x, y: c.y, t: t))
            }
            scanIncomplete = false
        } else {
            scanIncomplete = true
        }

        lastScanTime = frame.scanTime
        return events
    }

    /// Lift every finger. Used on device removal, sleep, and the stale-contact timeout.
    public mutating func releaseAll(at t: Double) -> [TouchEvent] {
        let events = active.keys.sorted().map { id -> TouchEvent in
            let c = active[id]!
            return .up(id: id, x: c.x, y: c.y, t: t)
        }
        active.removeAll()
        seenThisScan.removeAll()
        scanIncomplete = false
        return events
    }
}
