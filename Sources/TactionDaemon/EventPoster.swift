import Foundation
import AppKit
import CoreGraphics
import TactionKit

/// Turns `OutputAction`s into CGEvents. Owns the only mutable posting state: whether the
/// left button is down, the click counter for double clicks, and sub-pixel scroll remainders.
final class EventPoster {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var leftIsDown = false
    private var lastClickTime: Double = -1
    private var lastClickPoint = CGPoint.zero
    private var clickState: Int64 = 1
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    /// When true, actions are logged but not posted (calibration in progress, or dry run).
    var suppressed = false

    func post(_ actions: [OutputAction], now: Double) {
        for a in actions { post(a, now: now) }
    }

    func post(_ action: OutputAction, now: Double) {
        Log.debug("post", Formatting.describe(action))
        guard !suppressed else { return }
        switch action {
        case .moveTo(let p):
            let type: CGEventType = leftIsDown ? .leftMouseDragged : .mouseMoved
            mouse(type, at: p, button: .left, clickState: leftIsDown ? clickState : 0)?.post(tap: .cghidEventTap)

        case .leftDown(let p):
            updateClickState(at: p, now: now)
            leftIsDown = true
            mouse(.leftMouseDown, at: p, button: .left, clickState: clickState)?.post(tap: .cghidEventTap)

        case .leftUp(let p):
            leftIsDown = false
            mouse(.leftMouseUp, at: p, button: .left, clickState: clickState)?.post(tap: .cghidEventTap)

        case .leftClick(let p):
            updateClickState(at: p, now: now)
            mouse(.leftMouseDown, at: p, button: .left, clickState: clickState)?.post(tap: .cghidEventTap)
            mouse(.leftMouseUp, at: p, button: .left, clickState: clickState)?.post(tap: .cghidEventTap)
            leftIsDown = false

        case .rightClick(let p):
            mouse(.mouseMoved, at: p, button: .left, clickState: 0)?.post(tap: .cghidEventTap)
            mouse(.rightMouseDown, at: p, button: .right, clickState: 1)?.post(tap: .cghidEventTap)
            mouse(.rightMouseUp, at: p, button: .right, clickState: 1)?.post(tap: .cghidEventTap)

        case .scroll(let dx, let dy, let at, let phase):
            scroll(dx: dx, dy: dy, at: at, phase: phase)

        case .system(let action):
            keystroke(for: action)
        }
    }

    /// The user's actual Mission Control shortcuts. Reloaded on SIGHUP by the daemon.
    var hotkeys = SystemHotkeys()

    private func keystroke(for action: SystemAction) {
        switch hotkeys.resolve(action) {
        case .keystroke(let b):
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: b.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: b.keyCode, keyDown: false) else {
                Log.error("post", "keyboard event creation failed for \(action)")
                return
            }
            down.flags = b.flags
            up.flags = b.flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Log.debug("post", "\(action): \(hotkeys.describe(action))")

        case .launchMissionControl(let args):
            // No shortcut is enabled; Mission Control.app takes "2" for App Exposé and nothing for the overview.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: SystemHotkeys.missionControlApp)
            p.arguments = args
            do {
                try p.run()
                Log.debug("post", "\(action): launched Mission Control.app \(args)")
            } catch {
                Log.error("post", "\(action): could not launch Mission Control.app: \(error)")
            }

        case .unavailable(let reason):
            Log.error("post", "\(action) not performed: \(reason)")
        }
    }

    /// Emergency release, used at shutdown regardless of engine state.
    func releaseLeftIfDown(at p: CGPoint?) {
        guard leftIsDown else { return }
        let point = p ?? (CGEvent(source: nil)?.location ?? .zero)
        leftIsDown = false
        mouse(.leftMouseUp, at: point, button: .left, clickState: clickState)?.post(tap: .cghidEventTap)
    }

    // MARK: Helpers

    private func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, clickState: Int64) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
            Log.error("post", "CGEvent creation failed for \(type.rawValue)")
            return nil
        }
        if clickState > 0 { e.setIntegerValueField(.mouseEventClickState, value: clickState) }
        return e
    }

    /// Apps decide double clicks from the click state field, not from timing, so compute it here.
    private func updateClickState(at p: CGPoint, now: Double) {
        let interval = NSEvent.doubleClickInterval
        if now - lastClickTime <= interval && hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) <= 15 {
            clickState = min(clickState + 1, 3)
        } else {
            clickState = 1
        }
        lastClickTime = now
        lastClickPoint = p
    }

    private func scroll(dx: Double, dy: Double, at p: CGPoint, phase: ScrollPhase) {
        // Accumulate sub-point remainders so slow scrolls are not lost to integer truncation.
        scrollRemainderX += dx
        scrollRemainderY += dy
        let ix = Int32(scrollRemainderX.rounded(.towardZero))
        let iy = Int32(scrollRemainderY.rounded(.towardZero))
        scrollRemainderX -= Double(ix)
        scrollRemainderY -= Double(iy)
        if phase == .ended || phase == .momentumEnded { scrollRemainderX = 0; scrollRemainderY = 0 }

        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else {
            Log.error("post", "scroll event creation failed")
            return
        }
        e.location = p
        // Mark as trackpad-style continuous scrolling with phases so apps handle it like a trackpad.
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Finger-driven events carry a scroll phase; inertial ones carry a momentum phase instead.
        // Constants: kCGScrollPhaseBegan 1, Changed 2, Ended 4; kCGMomentumScrollPhaseBegin 1, Continue 2, End 3.
        var scrollPhase: Int64 = 0
        var momentumPhase: Int64 = 0
        switch phase {
        case .began: scrollPhase = 1
        case .changed: scrollPhase = 2
        case .ended: scrollPhase = 4
        case .momentumBegan: momentumPhase = 1
        case .momentumChanged: momentumPhase = 2
        case .momentumEnded: momentumPhase = 3
        }
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(iy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(ix))
        e.post(tap: .cghidEventTap)
    }
}
