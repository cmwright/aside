import AppKit
import XCTest
@testable import Aside

/// Only the pure, non-UI logic: the WAV header, the multipart body, the dictionary codec,
/// URL normalization and the leading-space rule.
final class AsideTests: XCTestCase {

    // MARK: - WAV

    func testWAVHeaderIsCanonical() throws {
        let pcm = Data(repeating: 0, count: 3200) // 1600 frames = 0.1 s at 16 kHz
        let file = WAV.file(pcm16: pcm)

        XCTAssertEqual(file.count, 44 + pcm.count)
        XCTAssertEqual(String(data: file[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: file[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: file[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: file[36..<40], encoding: .ascii), "data")

        XCTAssertEqual(le32(file, 4), UInt32(36 + pcm.count))   // RIFF size
        XCTAssertEqual(le32(file, 16), 16)                      // PCM fmt chunk size
        XCTAssertEqual(le16(file, 20), 1)                       // format = PCM
        XCTAssertEqual(le16(file, 22), 1)                       // mono
        XCTAssertEqual(le32(file, 24), 16_000)                  // sample rate
        XCTAssertEqual(le32(file, 28), 32_000)                  // byte rate
        XCTAssertEqual(le16(file, 32), 2)                       // block align
        XCTAssertEqual(le16(file, 34), 16)                      // bits per sample
        XCTAssertEqual(le32(file, 40), UInt32(pcm.count))       // data size
    }

    func testDurationMatchesMinimumGuard() {
        XCTAssertEqual(WAV.duration(ofPCM16: 32_000), 1.0, accuracy: 0.0001)
        // 0.29 s is below the 300 ms guard, 0.31 s is above it.
        XCTAssertLessThan(WAV.duration(ofPCM16: 9_280), Recorder.minimumDuration)
        XCTAssertGreaterThan(WAV.duration(ofPCM16: 9_920), Recorder.minimumDuration)
    }

    // MARK: - Multipart

    func testMultipartBodyMatchesContract() throws {
        let request = TranscriptionRequest(
            baseURL: URL(string: "http://localhost:8787")!,
            token: "t",
            audio: Data("WAVBYTES".utf8),
            dictionaryJSON: #"[{"replacement":"HyperComply","term":"hyper comply"}]"#,
            cleanup: .medium,
            appName: "Notes"
        )
        let body = BackendClient.multipartBody(boundary: "B", request: request)
        let text = String(data: body, encoding: .utf8)!

        XCTAssertTrue(text.contains("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nWAVBYTES\r\n"))
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ndefault\r\n"))
        XCTAssertTrue(text.contains("name=\"cleanup\"\r\n\r\nmedium\r\n"))
        XCTAssertTrue(text.contains("name=\"app_name\"\r\n\r\nNotes\r\n"))
        XCTAssertTrue(text.contains(#"name="dictionary""#))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
    }

    func testMultipartOmitsEmptyAppName() {
        var request = TranscriptionRequest(
            baseURL: URL(string: "http://x.test")!,
            token: nil,
            audio: Data(),
            dictionaryJSON: "[]",
            cleanup: .none,
            appName: nil
        )
        XCTAssertFalse(String(data: BackendClient.multipartBody(boundary: "B", request: request), encoding: .utf8)!
            .contains("app_name"))
        request.appName = ""
        XCTAssertFalse(String(data: BackendClient.multipartBody(boundary: "B", request: request), encoding: .utf8)!
            .contains("app_name"))
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(BackendClient.errorMessage(from: Data(#"{"error":"no key"}"#.utf8)), "no key")
        XCTAssertEqual(BackendClient.errorMessage(from: Data("boom".utf8)), "boom")
        XCTAssertEqual(BackendClient.errorMessage(from: Data()), "no details")
    }

    func testResponseDecodesContractShape() throws {
        let json = Data(#"{"text":"Hi.","raw_text":"hi","timing_ms":{"stt":10,"cleanup":5,"total":15}}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: json)
        XCTAssertEqual(decoded.text, "Hi.")
        XCTAssertEqual(decoded.rawText, "hi")
        XCTAssertEqual(decoded.timing?.total, 15)
    }

    // MARK: - Dictionary

    func testEncodeForRequestDropsEmptyTermsAndBlankReplacements() throws {
        let entries = [
            DictionaryEntry(term: "hyper comply", replacement: "HyperComply"),
            DictionaryEntry(term: "Kubernetes", replacement: "  "),
            DictionaryEntry(term: "   ", replacement: "ignored"),
        ]
        let json = DictionaryCodec.encodeForRequest(entries)
        let decoded = try JSONDecoder().decode([DictionaryEntry.Wire].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].replacement, "HyperComply")
        XCTAssertNil(decoded[1].replacement)
    }

    func testDictionaryRoundTrip() throws {
        let entries = [DictionaryEntry(term: "a", replacement: "A"), DictionaryEntry(term: "b")]
        let decoded = try DictionaryCodec.decode(try DictionaryCodec.encodeForFile(entries))
        XCTAssertEqual(decoded.map(\.term), ["a", "b"])
        XCTAssertEqual(decoded.map(\.replacement), ["A", nil])
    }

    func testMergePrefersImportedReplacement() {
        let merged = DictionaryStore.merge(
            existing: [DictionaryEntry(term: "Hyper Comply", replacement: "old")],
            imported: [DictionaryEntry(term: "hyper comply", replacement: "HyperComply"),
                       DictionaryEntry(term: "new term")]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].replacement, "HyperComply")
        XCTAssertEqual(merged[1].term, "new term")
    }

    // MARK: - Settings

    func testURLNormalization() {
        XCTAssertEqual(AppSettings.normalizedURL(from: " http://localhost:8787/ ")?.absoluteString, "http://localhost:8787")
        XCTAssertEqual(AppSettings.normalizedURL(from: "https://api.test///")?.absoluteString, "https://api.test")
        XCTAssertNil(AppSettings.normalizedURL(from: ""))
        XCTAssertNil(AppSettings.normalizedURL(from: "localhost:8787"))
        XCTAssertNil(AppSettings.normalizedURL(from: "ftp://x.test"))
    }

    func testRequestURLGetsContractPath() {
        let base = AppSettings.normalizedURL(from: "http://localhost:8787/")!
        XCTAssertEqual(base.appendingPathComponent("v1/audio/transcriptions").absoluteString,
                       "http://localhost:8787/v1/audio/transcriptions")
    }

    // MARK: - Leading space

    @MainActor
    func testLeadingSpaceRule() {
        XCTAssertTrue(TextInserter.needsLeadingSpace(precedingCharacter: "o", text: "hello"))
        XCTAssertTrue(TextInserter.needsLeadingSpace(precedingCharacter: "7", text: "hello"))
        XCTAssertFalse(TextInserter.needsLeadingSpace(precedingCharacter: " ", text: "hello"))
        XCTAssertFalse(TextInserter.needsLeadingSpace(precedingCharacter: "o", text: "!"))
        // No context readable -> never guess.
        XCTAssertFalse(TextInserter.needsLeadingSpace(precedingCharacter: nil, text: "hello"))
    }

    // MARK: - Right Option hold detection

    /// The bits AppKit sets in `modifierFlags.rawValue` for the physical Option keys.
    /// `NX_DEVICELALTKEYMASK` / `NX_DEVICERALTKEYMASK` from IOLLEvent.h.
    private static let leftOptionBit: UInt = 0x20
    private static let rightOptionBit: UInt = 0x40
    private static let genericOption = NSEvent.ModifierFlags.option.rawValue

    @MainActor
    func testRightOptionDownUsesTheDeviceSpecificBit() {
        let live = NSEvent.ModifierFlags.option

        // Right Option alone, pressed.
        XCTAssertTrue(AppController.rightOptionIsDown(
            eventFlags: Self.genericOption | Self.rightOptionBit, liveFlags: live))

        // Both held, then Right Option released: the generic .option bit is still set
        // because Left Option is down, but the right device bit is gone. This is the case
        // that used to wedge the recorder.
        XCTAssertFalse(AppController.rightOptionIsDown(
            eventFlags: Self.genericOption | Self.leftOptionBit, liveFlags: live))

        // Both held down.
        XCTAssertTrue(AppController.rightOptionIsDown(
            eventFlags: Self.genericOption | Self.leftOptionBit | Self.rightOptionBit, liveFlags: live))

        // Everything released.
        XCTAssertFalse(AppController.rightOptionIsDown(eventFlags: 0, liveFlags: []))
    }

    @MainActor
    func testStaleDownIsVetoedByLiveHardwareState() {
        // A stale event that still claims Right Option is down, while the hardware reports
        // no Option key held at all, counts as a release.
        XCTAssertFalse(AppController.rightOptionIsDown(
            eventFlags: Self.genericOption | Self.rightOptionBit, liveFlags: [.shift]))
    }

    @MainActor
    func testRightOptionMaskMatchesIOKitConstant() {
        XCTAssertEqual(AppController.rightOptionDeviceMask, 0x40) // NX_DEVICERALTKEYMASK
        XCTAssertEqual(AppController.rightOptionKeyCode, 61)      // kVK_RightOption
    }

    // MARK: - Recorder errors

    func testMicrophonePromptErrorTellsTheUserWhatToDo() {
        XCTAssertEqual(RecorderError.needsMicrophonePrompt.errorDescription,
                       "Allow microphone access, then hold the key again")
        XCTAssertNotEqual(RecorderError.microphoneDenied.errorDescription,
                          RecorderError.needsMicrophonePrompt.errorDescription)
    }

    // MARK: - TriggerLogic

    func testHoldStartsAndSends() {
        var t = TriggerLogic()
        XCTAssertEqual(t.keyDown(at: 0), .start)
        XCTAssertEqual(t.keyUp(at: 1.2), .send)
        XCTAssertFalse(t.latched)
    }

    func testDoubleTapLatchesAndNextPressStops() {
        var t = TriggerLogic()
        XCTAssertEqual(t.keyDown(at: 0), .start)
        XCTAssertEqual(t.keyUp(at: 0.1), .tapPending)
        XCTAssertEqual(t.keyDown(at: 0.25), .latch)
        XCTAssertTrue(t.latched)
        XCTAssertEqual(t.keyUp(at: 0.35), .ignore, "release after the latching press does nothing")
        XCTAssertEqual(t.tapWindowExpired(), .ignore, "an expiring window must not discard a latched recording")
        XCTAssertEqual(t.keyDown(at: 5), .stopLatched)
        XCTAssertFalse(t.latched)
        XCTAssertEqual(t.keyUp(at: 5.1), .ignore)
    }

    func testSingleTapDiscardsWhenWindowExpires() {
        var t = TriggerLogic()
        XCTAssertEqual(t.keyDown(at: 0), .start)
        XCTAssertEqual(t.keyUp(at: 0.1), .tapPending)
        XCTAssertEqual(t.tapWindowExpired(), .discard)
        XCTAssertEqual(t.keyDown(at: 2), .start, "a later press is a fresh gesture, not a latch")
    }

    func testSecondPressOutsideWindowIsAFreshStart() {
        var t = TriggerLogic()
        _ = t.keyDown(at: 0)
        XCTAssertEqual(t.keyUp(at: 0.1), .tapPending)
        XCTAssertEqual(t.keyDown(at: 1.0), .start)
    }

    func testDisabledWindowAlwaysSends() {
        var t = TriggerLogic()
        t.doubleTapWindow = 0
        XCTAssertEqual(t.keyDown(at: 0), .start)
        XCTAssertEqual(t.keyUp(at: 0.05), .send)
        XCTAssertEqual(t.keyDown(at: 0.1), .start)
    }

    func testResetClearsLatch() {
        var t = TriggerLogic()
        _ = t.keyDown(at: 0); _ = t.keyUp(at: 0.1); _ = t.keyDown(at: 0.2)
        XCTAssertTrue(t.latched)
        t.reset()
        XCTAssertFalse(t.latched)
        XCTAssertEqual(t.keyDown(at: 1), .start)
    }

    // MARK: - Local transcription

    func testFloatSamplesFromPCM16() {
        var pcm = Data()
        for value: Int16 in [0, 16384, -16384, 32767, -32768] {
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let samples = LocalTranscriber.floatSamples(fromPCM16: pcm)
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[2], -0.5, accuracy: 0.0001)
        XCTAssertEqual(samples[3], 32767.0 / 32768.0, accuracy: 0.0001)
        XCTAssertEqual(samples[4], -1, accuracy: 0.0001)
    }

    func testPCM16FromWAVFileStripsHeader() {
        let pcm = Data([1, 2, 3, 4])
        let file = WAV.file(pcm16: pcm)
        XCTAssertEqual(file.count, 48)
        XCTAssertEqual(WAV.pcm16(fromFile: file), pcm)
        XCTAssertEqual(WAV.pcm16(fromFile: Data([0, 1, 2])), Data())
    }

    func testCleanupBodyShape() throws {
        let body = BackendClient.cleanupBody(CleanupRequest(
            baseURL: URL(string: "http://localhost:8787")!, token: nil, text: "um hello",
            dictionaryJSON: "[{\"term\":\"x\"}]", cleanup: .light, appName: "Notes"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "um hello")
        XCTAssertEqual(object["dictionary"] as? String, "[{\"term\":\"x\"}]")
        XCTAssertEqual(object["cleanup"] as? String, "light")
        XCTAssertEqual(object["app_name"] as? String, "Notes")
    }

    /// Real model, real audio. Skipped unless VTT_LOCAL_ASR_TEST=1 because it downloads
    /// ~600 MB on first run. Run once to prove the pipeline and warm the cache:
    ///   VTT_LOCAL_ASR_TEST=1 xcodebuild ... test -only-testing:AsideTests/AsideTests/testParakeetTranscribesFixture
    @MainActor
    func testParakeetTranscribesFixture() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VTT_LOCAL_ASR_TEST"] == "1")
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("worker/test/fixtures/hello.wav")
        let file = try Data(contentsOf: fixture)
        let text = try await LocalTranscriber.shared.transcribe(pcm16: WAV.pcm16(fromFile: file))
        print("Parakeet: \(text)")
        XCTAssertTrue(text.lowercased().contains("hello"), "got: \(text)")
        XCTAssertTrue(text.lowercased().contains("test"), "got: \(text)")
    }

    /// Streaming (fed while "recording") must produce the same words as the whole-clip path
    /// on a clip long enough to cross two 11 s window seams. Same gate as above. The clip is
    /// synthesized with `say`, so no fixture file is needed.
    @MainActor
    func testStreamingSessionMatchesWholeClip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VTT_LOCAL_ASR_TEST"] == "1")
        let pcm = try Self.synthesizedSpeech(
            "Hello there, this is a longer test of dictation on this Mac. I am going to keep talking for a while so that the recording runs well past the first eleven second window. The quick brown fox jumps over the lazy dog, and then it goes back and does it again because nobody was watching the first time. We should also mention a few product names like HyperComply and a number like forty two, plus a question: does the streaming path drop or repeat words at the seams? Let us find out by comparing it against the whole clip transcription that the app used before this change.")
        XCTAssertGreaterThan(WAV.duration(ofPCM16: pcm.count), 25, "clip should cross two window seams")

        let transcriber = LocalTranscriber.shared
        var started = Date()
        let whole = try await transcriber.transcribe(pcm16: pcm)
        let wholeMs = Int(Date().timeIntervalSince(started) * 1000)

        let session = try XCTUnwrap(transcriber.beginSession(), "model is loaded, so a session must start")
        // Feed like the microphone tap does: ~85 ms chunks.
        let samples = LocalTranscriber.floatSamples(fromPCM16: pcm)
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1365, samples.count)
            session.feed(Array(samples[offset..<end]))
            offset = end
        }
        // Give the background windows a moment, as they would have during a real recording.
        try await Task.sleep(for: .seconds(1))
        started = Date()
        let streamed = try await session.finish()
        let tailMs = Int(Date().timeIntervalSince(started) * 1000)

        print("Whole clip (\(wholeMs) ms): \(whole)")
        print("Streaming (tail \(tailMs) ms): \(streamed)")
        let a = Self.words(whole), b = Self.words(streamed)
        let distance = Self.editDistance(a, b)
        XCTAssertLessThanOrEqual(Double(distance) / Double(max(a.count, 1)), 0.05,
                                 "\(distance) word edits between whole-clip and streaming transcripts")
    }

    // MARK: - Dictionary post-pass (Swift port)

    private let hc = [DictionaryEntry(term: "hyper comply", replacement: "HyperComply")]

    func testReplacerBasicsMatchWorker() {
        XCTAssertEqual(DictionaryReplacer.apply("a test of hyper comply dictation", entries: hc), "a test of HyperComply dictation")
        XCTAssertEqual(DictionaryReplacer.apply("Hyper Comply rocks", entries: hc), "HyperComply rocks")
        XCTAssertEqual(DictionaryReplacer.apply("hyper-comply and hypercomply", entries: hc), "HyperComply and HyperComply")
        XCTAssertEqual(DictionaryReplacer.apply("hypercomplying is not a word", entries: hc), "hypercomplying is not a word")
    }

    func testReplacerWordBoundariesAndEmpty() {
        let e = [DictionaryEntry(term: "comply", replacement: "Comply!")]
        XCTAssertEqual(DictionaryReplacer.apply("compliance means you comply.", entries: e), "compliance means you Comply!.")
        XCTAssertEqual(DictionaryReplacer.apply("nothing here", entries: []), "nothing here")
        XCTAssertEqual(DictionaryReplacer.apply("", entries: hc), "")
        XCTAssertEqual(DictionaryReplacer.apply("keep me", entries: [DictionaryEntry(term: "keep", replacement: nil)]), "keep me")
    }

    func testReplacerLongestWinsAndNoCascade() {
        let e = [DictionaryEntry(term: "a", replacement: "b"), DictionaryEntry(term: "b", replacement: "c"),
                 DictionaryEntry(term: "big a", replacement: "BIG")]
        XCTAssertEqual(DictionaryReplacer.apply("a b big a", entries: e), "b c BIG")
    }

    func testReplacerEscapesRegexMetacharacters() {
        let e = [DictionaryEntry(term: "c++", replacement: "C++")]
        XCTAssertEqual(DictionaryReplacer.apply("i like c++ a lot", entries: e), "i like C++ a lot")
    }

    // MARK: - Cleanup prompt

    func testSimilarityGuard() {
        XCTAssertEqual(AppleCleanup.similarity(raw: "um hello there team", cleaned: "Hello there, team."), 0.75, accuracy: 0.01)
        XCTAssertLessThan(AppleCleanup.similarity(raw: "what time is the meeting", cleaned: "Sure, I can help with that!"), 0.5)
        XCTAssertEqual(AppleCleanup.similarity(raw: "", cleaned: "anything"), 1)
    }

    func testCleanupInstructionsMirrorWorker() {
        let light = CleanupPrompt.instructions(level: .light, entries: [])
        let medium = CleanupPrompt.instructions(level: .medium, entries: hc)
        XCTAssertTrue(light.contains("Do not remove filler words"))
        XCTAssertFalse(light.contains("User dictionary"))
        XCTAssertTrue(medium.contains("Remove filler words"))
        XCTAssertTrue(medium.contains("sounds like \"hyper comply\", write it as \"HyperComply\""))
        XCTAssertEqual(CleanupPrompt.sanitize("\"Hello there.\""), "Hello there.")
        XCTAssertEqual(CleanupPrompt.sanitize("  plain  "), "plain")
    }

    // MARK: - Helpers

    /// 16 kHz mono Int16 PCM of `text` spoken by the system voice.
    private static func synthesizedSpeech(_ text: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aside-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appendingPathComponent("speech.aiff"), wav = dir.appendingPathComponent("speech.wav")
        for (tool, args) in [
            ("/usr/bin/say", ["-o", aiff.path, text]),
            ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]),
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("\(tool) failed with \(process.terminationStatus)") }
        }
        return WAV.pcm16(fromFile: try Data(contentsOf: wav))
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where i <= a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where j <= b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0..<4).reversed() { value = (value << 8) | UInt32(data[data.startIndex + offset + index]) }
        return value
    }

    private func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }
}
