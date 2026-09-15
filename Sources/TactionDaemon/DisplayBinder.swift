import Foundation
import AppKit
import CoreGraphics
import TactionKit

struct ResolvedDisplay: Equatable {
    var id: CGDirectDisplayID
    var name: String
    var vendor: UInt32
    var model: UInt32
    var geometry: DisplayGeometry
    var mirroredInto: CGDirectDisplayID?
    var matchedBy: String

    var summary: String {
        let f = geometry.geometry
        var s = "\(name) id=\(id) vendor=\(vendor) model=\(model) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))) rotation=\(geometry.rotation) via \(matchedBy)"
        if let m = mirroredInto { s += " (mirrored, using display \(m) bounds)" }
        return s
    }
}

private extension DisplayGeometry {
    var geometry: CGRect { frame }
}

/// Finds the ZenScreen among the online displays. See taction/04-project-daemon.md, "Display binding".
enum DisplayBinder {
    struct Candidate {
        var id: CGDirectDisplayID
        var vendor: UInt32
        var model: UInt32
        var name: String
        var builtin: Bool
    }

    static func onlineDisplays() -> [Candidate] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            Candidate(id: id,
                      vendor: CGDisplayVendorNumber(id),
                      model: CGDisplayModelNumber(id),
                      name: screenName(for: id) ?? "display \(id)",
                      builtin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    static func screenName(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber, n.uint32Value == id {
                return screen.localizedName
            }
        }
        return nil
    }

    static func resolve(_ binding: DisplayBinding) -> ResolvedDisplay? {
        let all = onlineDisplays()
        let external = all.filter { !$0.builtin }

        func make(_ c: Candidate, _ how: String) -> ResolvedDisplay {
            var boundsSource = c.id
            var mirroredInto: CGDirectDisplayID?
            if CGDisplayIsInMirrorSet(c.id) != 0 {
                let primary = CGDisplayMirrorsDisplay(c.id)
                if primary != kCGNullDirectDisplay {
                    boundsSource = primary
                    mirroredInto = primary
                }
            }
            let geometry = DisplayGeometry(frame: CGDisplayBounds(boundsSource), rotation: Int(CGDisplayRotation(c.id).rounded()))
            return ResolvedDisplay(id: c.id, name: c.name, vendor: c.vendor, model: c.model, geometry: geometry, mirroredInto: mirroredInto, matchedBy: how)
        }

        if let vendor = binding.vendor {
            if let model = binding.model, let c = external.first(where: { $0.vendor == vendor && $0.model == model }) {
                return make(c, "vendor+model")
            }
            let byVendor = external.filter { $0.vendor == vendor }
            if byVendor.count == 1 { return make(byVendor[0], "vendor") }
            if byVendor.count > 1, let named = byVendor.first(where: { $0.name.localizedCaseInsensitiveContains(binding.nameFallback) }) {
                return make(named, "vendor+name")
            }
        }
        let needle = binding.nameFallback
        if !needle.isEmpty, let c = external.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) {
            return make(c, "name")
        }
        return nil
    }

    static func describeAll() -> String {
        onlineDisplays().map { c in
            let b = CGDisplayBounds(c.id)
            return "\(c.name) id=\(c.id) vendor=\(c.vendor) model=\(c.model) builtin=\(c.builtin) frame=(\(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height))) rotation=\(Int(CGDisplayRotation(c.id)))"
        }.joined(separator: "; ")
    }
}
