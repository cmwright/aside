import Foundation

/// Decides what each Right Option press and release means. Pure and clock-free so it can
/// be unit-tested; the controller feeds it event timestamps and acts on the returned action.
///
/// Gestures:
/// - Hold: press, speak, release -> `.start` then `.send`.
/// - Double-tap: two quick presses -> `.start`, `.tapPending`, `.latch`. Recording keeps
///   running after the second release. The next press -> `.stopLatched`.
/// - Single quick tap with no second press -> `.tapPending`, then `.discard` when the
///   window expires (nothing useful was said in a third of a second).
struct TriggerLogic: Sendable {
    enum Action: Equatable, Sendable {
        case start, send, tapPending, latch, stopLatched, discard, ignore
    }

    /// A press shorter than this is a tap, and a second press within this much of the
    /// first release latches. Set to 0 to disable the double-tap gesture entirely.
    var doubleTapWindow: TimeInterval = 0.35

    private(set) var latched = false
    private var pressStart: TimeInterval?
    private var lastTapEnd: TimeInterval?

    mutating func keyDown(at time: TimeInterval) -> Action {
        if latched {
            reset()
            return .stopLatched
        }
        if let tapEnd = lastTapEnd, doubleTapWindow > 0, time - tapEnd <= doubleTapWindow {
            lastTapEnd = nil
            pressStart = nil
            latched = true
            return .latch
        }
        pressStart = time
        return .start
    }

    mutating func keyUp(at time: TimeInterval) -> Action {
        guard let start = pressStart else { return .ignore }
        pressStart = nil
        if doubleTapWindow > 0, time - start <= doubleTapWindow {
            lastTapEnd = time
            return .tapPending
        }
        return .send
    }

    /// The double-tap window elapsed after a quick tap with no second press.
    mutating func tapWindowExpired() -> Action {
        guard lastTapEnd != nil, !latched else { return .ignore }
        lastTapEnd = nil
        return .discard
    }

    /// Recording ended for any other reason (menu, shortcut, watchdog, error).
    mutating func reset() {
        latched = false
        pressStart = nil
        lastTapEnd = nil
    }
}
