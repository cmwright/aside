@preconcurrency import AVFoundation
import Foundation

/// Builds a 16 kHz mono 16-bit PCM WAV file — exactly what the HTTP contract asks for.
/// Compiled into the Mac app and the iPhone app; each has its own recorder around it.
enum WAV {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerSample = 16

    /// Wraps raw little-endian Int16 PCM in a canonical 44-byte RIFF/WAVE header.
    static func file(pcm16: Data, sampleRate: Int = WAV.sampleRate, channels: Int = WAV.channels) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var out = Data(capacity: 44 + pcm16.count)

        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }

        out.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm16.count))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        append32(16)                       // PCM chunk size
        append16(1)                        // format = PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))
        out.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm16.count))
        out.append(pcm16)
        return out
    }

    /// The raw Int16 PCM inside a file produced by `file(pcm16:)` (canonical 44-byte header).
    static func pcm16(fromFile data: Data) -> Data {
        data.count > 44 ? Data(data.suffix(from: data.startIndex + 44)) : Data()
    }

    /// Seconds of audio in a raw Int16 mono buffer.
    static func duration(ofPCM16 bytes: Int, sampleRate: Int = WAV.sampleRate, channels: Int = WAV.channels) -> Double {
        let frames = Double(bytes) / Double(channels * bitsPerSample / 8)
        return frames / Double(sampleRate)
    }
}

/// Receives audio on the real-time render thread, converts it to 16 kHz mono Int16 and
/// appends to a lock-protected buffer, but only between `beginCapture` and `endCapture`.
/// Outside a capture `append` converts nothing and stores nothing, which is how the phone
/// keeps its engine running for a whole session while holding no audio between dictations.
/// Conversion uses a reusable output buffer and a separate lock; capture state is held
/// only while copying PCM. Storage is preallocated and bounded to the recording limit.
final class PCMSink: @unchecked Sendable {
    /// One-shot flag for the converter's input block. A reference type because Swift 6
    /// types that block as `@Sendable` even though `convert` runs it synchronously, and a
    /// captured `var` would be a data-race warning. Only ever touched under `lock`.
    private final class Handoff: @unchecked Sendable {
        var done = false
    }

    private let lock = NSLock()
    private var pcm = Data()
    private var capturing = false
    private let conversionLock = NSLock()
    private var outputBuffer: AVAudioPCMBuffer?
    private var captureGeneration: UInt64 = 0
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let handoff = Handoff()
    /// Gets a 0...1 level per converted chunk while capturing, for a meter. Render thread.
    private var levelListener: (@Sendable (Float) -> Void)?

    let outputFormat: AVAudioFormat = {
        // Force-unwrap: this combination is always supported by CoreAudio.
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: Double(WAV.sampleRate),
                      channels: AVAudioChannelCount(WAV.channels),
                      interleaved: true)!
    }()

    /// Starts keeping audio.
    func beginCapture(levelListener: (@Sendable (Float) -> Void)? = nil) {
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        pcm.reserveCapacity(WAV.sampleRate * 2 * 92)
        captureGeneration &+= 1
        capturing = true
        self.levelListener = levelListener
        lock.unlock()
    }

    /// Ends capture and hands back the raw Int16 PCM.
    func endCapture() -> Data {
        lock.lock()
        let out = pcm
        pcm = Data()
        capturing = false
        levelListener = nil
        lock.unlock()
        return out
    }

    /// Ends capture and throws the audio away.
    func discard() {
        lock.lock()
        pcm = Data()
        capturing = false
        levelListener = nil
        lock.unlock()
    }

    var capturedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return WAV.duration(ofPCM16: pcm.count)
    }

    /// Drops the cached converter so the next buffer rebuilds it. Used when the engine
    /// reports a configuration or route change (Bluetooth headset switching formats, etc).
    func invalidateConverter() {
        conversionLock.lock()
        converter = nil
        inputFormat = nil
        outputBuffer = nil
        conversionLock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let generation = captureGeneration
        let shouldCapture = capturing
        lock.unlock()
        guard shouldCapture else { return }

        conversionLock.lock()
        defer { conversionLock.unlock() }
        if converter == nil || inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let converter, buffer.frameLength > 0 else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        if outputBuffer == nil || outputBuffer!.frameCapacity < capacity {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let out = outputBuffer else { return }
        out.frameLength = 0

        handoff.done = false
        var error: NSError?
        let handoff = self.handoff
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if handoff.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            handoff.done = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let frames = Int(out.frameLength)
        lock.lock()
        guard capturing, captureGeneration == generation else { lock.unlock(); return }
        // A stalled controller must not let capture grow without bound.
        let remaining = max(0, WAV.sampleRate * 2 * 92 - pcm.count)
        channel[0].withMemoryRebound(to: UInt8.self, capacity: frames * 2) { bytes in
            pcm.append(bytes, count: min(frames * 2, remaining))
        }
        let listener = levelListener
        lock.unlock()
        if let levelListener = listener {
            var sum: Float = 0
            for index in 0..<frames { let v = Float(channel[0][index]) / 32768; sum += v * v }
            // RMS on a square-root curve: quiet speech still moves the meter.
            levelListener(min(1, (sum / Float(frames)).squareRoot().squareRoot() * 1.6))
        }
    }
}
