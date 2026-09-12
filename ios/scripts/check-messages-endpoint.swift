// Run from the repository root:
// xcrun swiftc ios/Messages/SilenceEndpoint.swift ios/scripts/check-messages-endpoint.swift -o /tmp/aside-endpoint-check
// /tmp/aside-endpoint-check
import Foundation

@main
struct MessagesEndpointChecks {
    static func run(_ segments: [(Float, Int)]) -> (stopped: Bool, detector: SilenceEndpoint) {
        var detector = SilenceEndpoint()
        var tick = 0
        for (level, count) in segments {
            for _ in 0..<count {
                if detector.update(level: level, at: Double(tick) / 10) { return (true, detector) }
                tick += 1
            }
        }
        return (false, detector)
    }
    static func main() {
        precondition(!run([(0, 100)]).stopped, "Initial silence must not stop")
        precondition(!run([(0.6, 1), (0, 50)]).stopped, "A click must not arm stopping")
        precondition(!run([(0.6, 10), (0, 19)]).stopped, "A short pause must not stop")
        precondition(run([(0.6, 10), (0, 51)]).stopped, "Five seconds of silence should stop")
        precondition(!run([(0.6, 10), (0, 15), (0.6, 5), (0, 15)]).stopped, "Resuming speech resets pause")
        precondition(!run([(0.6, 100)]).stopped, "Continuous speech must not stop")
        precondition(!run([(0.1, 100)]).detector.heardSpeech, "Quiet room noise must not arm stopping")
        var gate = run([(0.6, 10)]).detector
        precondition(!gate.update(level: 0, at: 2.9) && gate.countdown == 3)
        precondition(!gate.update(level: 0, at: 3.9) && gate.countdown == 2)
        precondition(!gate.update(level: 0, at: 4.9) && gate.countdown == 1)
        precondition(!gate.update(level: 0.6, at: 5) && gate.countdown == nil, "Speech cancels countdown")
        precondition(!gate.update(level: 0, at: 7) && gate.countdown == 3)
        gate.keepRecording()
        precondition(gate.countdown == nil)
        precondition(!gate.update(level: 0, at: 30), "Keep recording waits for speech instead of nagging again")
        precondition(!gate.update(level: 0.6, at: 31))
        precondition(!gate.update(level: 0, at: 33) && gate.countdown == 3)
        precondition(gate.update(level: 0, at: 36), "Next spoken phrase rearms automatic stop")
        print("17 endpoint checks passed")
    }
}
