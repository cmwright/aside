import Foundation

/// Decides what each press and release of the dictation key means: Right Option on the
/// Mac, the mic button on the iPhone keyboard and Home tab. Pure and clock-free so it can
/// be unit-tested; the controller feeds it event timestamps and acts on the returned action.
///
/// Holding always works: press, speak, release -> `.start` then `.send`. What a quick tap
/// means is `tapBehavior`:
/// - `.latch` (default): one tap -> `.start`, `.latch`. Recording keeps running hands-free
///   until the next press -> `.stopLatched`.
/// - `.doubleTapLatches`: a tap alone is nothing; two quick taps -> `.start`, `.tapPending`,
///   `.latch`. A single tap with no second press -> `.tapPending`, then `.discard` when the
///   window expires (nothing useful was said in a third of a second).
/// - `.send`: a tap is just a short hold and sends whatever was captured.
struct TriggerLogic: Sendable {
    enum Action: Equatable, Sendable {
        case start, send, tapPending, latch, stopLatched, discard, ignore
    }

    /// What a press shorter than `tapWindow` does. Stored by both apps under
    /// `defaultsKey`; the keyboard extension reads it from the App Group suite.
    enum TapBehavior: String, CaseIterable, Identifiable, Sendable {
        case latch
        case doubleTapLatches
        case send

        var id: String { rawValue }
        static let defaultsKey = "tapBehavior"

        /// The stored preference, or the default when nothing was ever chosen.
        static func stored(in defaults: UserDefaults?) -> TapBehavior {
            guard let raw = defaults?.string(forKey: defaultsKey) else { return .latch }
            return TapBehavior(rawValue: raw) ?? .latch
        }
    }

    var tapBehavior: TapBehavior = .latch

    /// A press shorter than this is a tap. In `.doubleTapLatches` mode a second press
    /// within this much of the first release latches.
    var tapWindow: TimeInterval = 0.35

    private(set) var latched = false
    private var pressStart: TimeInterval?
    private var lastTapEnd: TimeInterval?

    mutating func keyDown(at time: TimeInterval) -> Action {
        if latched {
            reset()
            return .stopLatched
        }
        if tapBehavior == .doubleTapLatches, let tapEnd = lastTapEnd, time - tapEnd <= tapWindow {
            lastTapEnd = nil
            pressStart = nil
            latched = true
            return .latch
        }
        lastTapEnd = nil
        pressStart = time
        return .start
    }

    mutating func keyUp(at time: TimeInterval) -> Action {
        guard let start = pressStart else { return .ignore }
        pressStart = nil
        guard time - start <= tapWindow else { return .send }
        switch tapBehavior {
        case .latch:
            latched = true
            return .latch
        case .doubleTapLatches:
            lastTapEnd = time
            return .tapPending
        case .send:
            return .send
        }
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
