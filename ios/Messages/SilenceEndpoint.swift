import Foundation

/// Uses the recorder's normalized RMS meter to find a pause after sustained sound.
/// This is an energy gate, not a classifier: background voices can keep it open.
struct SilenceEndpoint {
    private var previousTime: TimeInterval?
    private var soundDuration: TimeInterval = 0
    private var lastSound: TimeInterval?
    private(set) var heardSpeech = false
    private(set) var countdown: Int?

    mutating func keepRecording() {
        lastSound = nil
        soundDuration = 0
        countdown = nil
    }

    mutating func update(level: Float, at time: TimeInterval) -> Bool {
        let elapsed = previousTime.map { max(0, min(time - $0, 0.15)) } ?? 0
        previousTime = time
        if level >= (heardSpeech ? 0.32 : 0.40) {
            soundDuration += elapsed
            lastSound = time
            if soundDuration >= 0.25 { heardSpeech = true }
        } else {
            soundDuration = 0
        }
        countdown = nil
        guard heardSpeech, let lastSound else { return false }
        let quietSeconds = time - lastSound
        // Two seconds to notice the pause, then a visible three-second grace period.
        if quietSeconds >= 5 { return true }
        if quietSeconds >= 2 { countdown = max(1, Int(ceil(5 - quietSeconds))) }
        return false
    }
}
