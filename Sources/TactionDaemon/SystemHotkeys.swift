import Foundation
import CoreGraphics
import TactionKit

/// Resolves system actions to whatever keyboard shortcut the user actually has enabled, by reading
/// the same preferences System Settings > Keyboard > Keyboard Shortcuts writes
/// (`com.apple.symbolichotkeys`). Posting a hardcoded Ctrl+arrow does nothing on a Mac where that
/// shortcut is turned off, which is exactly this Mac: only the Ctrl+Shift variants are enabled.
///
/// Symbolic hotkey IDs, from Apple's Mission Control pane:
///   32 Mission Control, 33 App Exposé, 34 and 35 their Shift variants,
///   79 move left a Space, 80 its Shift variant, 81 move right a Space, 82 its Shift variant.
struct SystemHotkeys {
    struct Binding: Equatable {
        var keyCode: CGKeyCode
        var flags: CGEventFlags
        var hotkeyID: Int
    }

    private var entries: [Int: (enabled: Bool, keyCode: CGKeyCode, modifiers: UInt64)] = [:]
    private(set) var loadedAt = Date()

    static let missionControlApp = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"

    init() { reload() }

    mutating func reload() {
        entries = [:]
        loadedAt = Date()
        guard let dict = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] else {
            return
        }
        for (key, value) in dict {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? NSNumber)?.boolValue ?? true)
            guard let params = (entry["value"] as? [String: Any])?["parameters"] as? [Any], params.count >= 3,
                  let keyCode = (params[1] as? NSNumber)?.intValue, keyCode >= 0,
                  let mods = (params[2] as? NSNumber)?.uint64Value else { continue }
            entries[id] = (enabled, CGKeyCode(keyCode), mods)
        }
    }

    /// The first enabled binding among `ids`, or nil.
    func binding(for ids: [Int]) -> Binding? {
        for id in ids {
            guard let e = entries[id], e.enabled else { continue }
            // The stored modifier mask uses the same bit layout as CGEventFlags (shift 0x20000,
            // control 0x40000, option 0x80000, command 0x100000, fn 0x800000). Arrow keys on a real
            // keyboard also carry the numeric-pad flag, so add it for them.
            var flags = CGEventFlags(rawValue: e.modifiers)
            if (123...126).contains(Int(e.keyCode)) { flags.insert(.maskNumericPad) }
            return Binding(keyCode: e.keyCode, flags: flags, hotkeyID: id)
        }
        return nil
    }

    enum Resolution: Equatable {
        case keystroke(Binding)
        /// Run Mission Control.app with these arguments (none = Mission Control, "2" = App Exposé).
        case launchMissionControl(arguments: [String])
        case unavailable(reason: String)
    }

    func resolve(_ action: SystemAction) -> Resolution {
        switch action {
        case .previousSpace:
            if let b = binding(for: [79, 80]) { return .keystroke(b) }
            return .unavailable(reason: "no enabled shortcut for 'Move left a space' (enable one under System Settings > Keyboard > Keyboard Shortcuts > Mission Control)")
        case .nextSpace:
            if let b = binding(for: [81, 82]) { return .keystroke(b) }
            return .unavailable(reason: "no enabled shortcut for 'Move right a space' (enable one under System Settings > Keyboard > Keyboard Shortcuts > Mission Control)")
        case .missionControl:
            if let b = binding(for: [32, 34]) { return .keystroke(b) }
            return .launchMissionControl(arguments: [])
        case .appExpose:
            if let b = binding(for: [33, 35]) { return .keystroke(b) }
            return .launchMissionControl(arguments: ["2"])
        case .zoomIn:
            return .keystroke(Binding(keyCode: 0x18, flags: .maskCommand, hotkeyID: 0))   // Cmd+=
        case .zoomOut:
            return .keystroke(Binding(keyCode: 0x1B, flags: .maskCommand, hotkeyID: 0))   // Cmd+-
        }
    }

    func describe(_ action: SystemAction) -> String {
        switch resolve(action) {
        case .keystroke(let b): return "keystroke key=\(b.keyCode) flags=0x\(String(b.flags.rawValue, radix: 16))\(b.hotkeyID > 0 ? " (hotkey \(b.hotkeyID))" : "")"
        case .launchMissionControl(let args): return "launch Mission Control.app \(args)"
        case .unavailable(let reason): return "UNAVAILABLE: \(reason)"
        }
    }
}
