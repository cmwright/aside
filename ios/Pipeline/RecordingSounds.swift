import AudioToolbox
import Foundation

/// Short bundled-in-code tones, played through System Sound Services so they
/// respect the phone's sound settings without reconfiguring the recording session.
@MainActor
final class RecordingSounds {
    private var startID: SystemSoundID = 0
    private var stopID: SystemSoundID = 0

    init() {
        startID = Self.makeTone(name: "start", frequency: 880)
        stopID = Self.makeTone(name: "stop", frequency: 660)
    }

    func playStart() async {
        guard startID != 0 else { return }
        await withCheckedContinuation { continuation in
            AudioServicesPlaySystemSoundWithCompletion(startID, Self.completion(resuming: continuation))
        }
        // Let the speaker tail decay before restarting capture.
        try? await Task.sleep(for: .milliseconds(100))
    }

    // System Sound Services invokes this on SSClientCompletionQueue, not MainActor.
    // Resuming a checked continuation is thread-safe; the suspended task returns
    // to its own actor. Keep the callback explicitly nonisolated and Sendable.
    nonisolated static func completion(resuming continuation: CheckedContinuation<Void, Never>) -> @Sendable () -> Void {
        { @Sendable in continuation.resume() }
    }

    func playStop() {
        guard stopID != 0 else { return }
        AudioServicesPlaySystemSound(stopID)
    }

    private static func makeTone(name: String, frequency: Double) -> SystemSoundID {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aside-recording-\(name).wav")
        let samples = 1600
        var pcm = Data(capacity: samples * 2)
        for i in 0..<samples {
            let envelope = min(1, Double(i) / 160) * min(1, Double(samples - i) / 320)
            var value = Int16(4000 * envelope * sin(2 * .pi * frequency * Double(i) / 16000)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        do {
            try WAV.file(pcm16: pcm).write(to: url, options: .atomic)
            var id: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return 0 }
            return id
        } catch { return 0 }
    }

    deinit {
        AudioServicesDisposeSystemSoundID(startID)
        AudioServicesDisposeSystemSoundID(stopID)
    }
}
