import XCTest
import AVFoundation
@testable import Aside

private actor PipelineProbe {
    var attempts = 0
    var transcripts = 0
    func attempt() { attempts += 1 }
    func transcript() { transcripts += 1 }
}

final class PipelineTests: XCTestCase {
    @MainActor
    private func plan() -> DictationPlan {
        let name = "aside.pipeline.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionMode = .local
        settings.cleanupEngine = .apple
        return DictationPlan(settings: settings, entries: [DictionaryEntry(term: "acme cloud", replacement: "AcmeCloud")])
    }

    @MainActor
    func testCleanupFailureKeepsCheckpointAndDictionaryOnBothPlatforms() async throws {
        let probe = PipelineProbe()
        var pipeline = DictationPipeline()
        pipeline.retryDelay = 0
        pipeline.localSpeech = { _ in "hello acme cloud" }
        pipeline.appleCleanup = { _, _, _ in
            await probe.attempt()
            throw URLError(.networkConnectionLost)
        }
        let result = try await pipeline.run(audio: Data(), plan: plan()) { raw in
            XCTAssertEqual(raw.raw, "hello acme cloud")
            await probe.transcript()
        }
        let attempts = await probe.attempts
        let transcripts = await probe.transcripts
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(transcripts, 1)
        XCTAssertEqual(result.text, "hello AcmeCloud")
        XCTAssertNotNil(result.warning)
    }

    @MainActor
    func testCleanupDeadlineFallsBackWithoutLosingSpeech() async throws {
        var pipeline = DictationPipeline()
        pipeline.cleanupAttemptSeconds = 0.01
        pipeline.retryDelay = 0
        pipeline.localSpeech = { _ in "keep these words" }
        pipeline.appleCleanup = { raw, _, _ in
            try await Task.sleep(for: .seconds(30))
            return raw
        }
        let started = Date()
        let result = try await pipeline.run(audio: Data(), plan: plan())
        XCTAssertEqual(result.text, "keep these words")
        XCTAssertNotNil(result.warning)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    @MainActor
    func testCancellationDoesNotRetryOrReturnFallback() async throws {
        let probe = PipelineProbe()
        var pipeline = DictationPipeline()
        pipeline.retryDelay = 0
        pipeline.localSpeech = { _ in "cancel these words" }
        pipeline.appleCleanup = { raw, _, _ in
            await probe.attempt()
            try await Task.sleep(for: .seconds(30))
            return raw
        }
        let configured = pipeline
        let plan = plan()
        let task = Task { try await configured.run(audio: Data(), plan: plan) }
        for _ in 0..<100 {
            if await probe.attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not become a successful raw fallback")
        } catch { XCTAssertTrue(error is CancellationError) }
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)
    }

    @MainActor
    func testCancelledSpeechCannotProceedToCleanup() async throws {
        let probe = PipelineProbe()
        var pipeline = DictationPipeline()
        pipeline.localSpeech = { _ in
            // Simulate an engine that completes despite cancellation.
            await probe.transcript()
            try? await Task.sleep(for: .seconds(30))
            return "old recording"
        }
        pipeline.appleCleanup = { raw, _, _ in await probe.attempt(); return raw }
        let configured = pipeline
        let plan = plan()
        let task = Task { try await configured.run(audio: Data(), plan: plan) }
        for _ in 0..<100 {
            if await probe.transcripts > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await probe.transcripts
        XCTAssertEqual(started, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 0)
    }

    @MainActor
    func testProviderSwitchRestoresOnlyThatProvidersOverrides() {
        let name = "aside.providers.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.directChatProvider = "custom"
        settings.directChatBaseURL = "https://custom.example/v1"
        settings.directChatModel = "custom-model"
        settings.directChatProvider = "cerebras"
        XCTAssertEqual(settings.directChatBaseURL, "")
        XCTAssertEqual(settings.directChatModel, "")
        settings.directChatModel = "chosen-cerebras-model"
        settings.directChatProvider = "custom"
        XCTAssertEqual(settings.directChatBaseURL, "https://custom.example/v1")
        XCTAssertEqual(settings.directChatModel, "custom-model")
        settings.directChatProvider = "cerebras"
        XCTAssertEqual(settings.directChatModel, "chosen-cerebras-model")
        let reloaded = AppSettings(defaults: defaults)
        reloaded.directChatProvider = "custom"
        XCTAssertEqual(reloaded.directChatBaseURL, "https://custom.example/v1")
        settings.directSttProvider = "custom"
        settings.directSttBaseURL = "https://speech.example/v1"
        settings.directSttModel = "speech-model"
        settings.directSttProvider = "groq"
        XCTAssertEqual(settings.directSttBaseURL, "")
        XCTAssertEqual(settings.directSttModel, "")
        settings.directSttProvider = "custom"
        XCTAssertEqual(settings.directSttBaseURL, "https://speech.example/v1")
        XCTAssertEqual(settings.directSttModel, "speech-model")
    }

    func testCaptureDiscardsIdleAudioAndBoundsLongRecordings() throws {
        let sink = PCMSink()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sink.outputFormat, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.int16ChannelData)
        samples[0].initialize(repeating: 0, count: 16_000)
        sink.append(buffer)
        XCTAssertEqual(sink.capturedSeconds, 0)
        sink.beginCapture()
        for _ in 0..<94 { sink.append(buffer) }
        XCTAssertLessThanOrEqual(sink.capturedSeconds, 92)
        XCTAssertGreaterThan(sink.capturedSeconds, 91)
        _ = sink.endCapture()
        sink.append(buffer)
        XCTAssertEqual(sink.capturedSeconds, 0)
        sink.beginCapture()
        sink.append(buffer)
        XCTAssertGreaterThan(sink.capturedSeconds, 0)
        XCTAssertLessThanOrEqual(sink.capturedSeconds, 1)
        sink.discard()
        XCTAssertEqual(sink.capturedSeconds, 0)
    }

    @MainActor
    func testQueuedHistoryCannotReappearAfterClear() async throws {
        let name = "aside.history.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults)
        settings.historyRetention = .forever
        let file = root.appendingPathComponent("history.json")
        let history = DictationHistory(fileURL: file, settings: settings)
        let id = UUID()
        for index in 0..<20 {
            history.add(DictationRecord(id: id, date: Date(), engine: .local, rawText: "raw",
                finalText: "revision \(index)", sttMs: 0, cleanupMs: 0, cleanupLabel: "test"))
        }
        XCTAssertEqual(history.records.count, 1, "Checkpoint and final text share one history entry")
        history.clear()
        await history.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
