import Foundation

// Local model and keychain are replaced only in this test executable. Remote calls
// use the production DirectClient with URLProtocol interception: nothing leaves here.
@MainActor final class LocalTranscriber {
    static let shared = LocalTranscriber()
    var calls = 0
    func transcribe(pcm16: Data) async throws -> String { calls += 1; return "local transcript" }
}
enum APIKeyStore { static func key(for providerID: String) -> String? { "fixture-key" } }
final class MockProvider: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var chat = "Hello world."
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let json: [String: Any] = request.url!.path.hasSuffix("transcriptions")
            ? ["text": "hello world"] : ["choices": [["message": ["content": Self.chat]]]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Checks {
    @MainActor static func main() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let completion = RecordingSounds.completion(resuming: continuation)
            DispatchQueue(label: "test.audio-completion").async(execute: completion)
        }
        print("Sound completion resumed safely from a background queue")
        let suite = "aside-provider-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.transcriptionMode = .direct
        settings.cleanupEngine = .direct
        settings.directSttProvider = "custom"
        settings.directChatProvider = "custom"
        settings.directSttBaseURL = "https://speech.invalid/v1"
        settings.directChatBaseURL = "https://cleanup.invalid/v1"
        settings.directSttModel = "chosen-speech"
        settings.directChatModel = "chosen-cleanup"
        settings.cleanup = .light
        var plan = DictationPipeline.plan(settings: settings, entries: [])
        precondition(plan.mode == .direct && plan.cleanup.engine == .direct && plan.cleanup.level == .light)
        precondition(plan.speech?.model == "chosen-speech" && plan.cleanup.direct?.model == "chosen-cleanup")
        settings.directSttModel = "changed-later"
        precondition(plan.speech?.model == "chosen-speech", "Recording snapshot must stay stable")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProvider.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = DirectClient(session: session)
        let raw = try await DictationPipeline.transcribe(audio: WAV.file(pcm16: Data([0,0,0,0])), plan: plan, direct: client)
        precondition(raw == "hello world")
        let result = try await DictationPipeline.clean(raw: raw, plan: plan.cleanup, direct: client)
        precondition(result.text == "Hello world.")
        precondition(MockProvider.requests.map { $0.url!.host! } == ["speech.invalid", "cleanup.invalid"])
        precondition(MockProvider.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" })
        precondition(LocalTranscriber.shared.calls == 0, "Direct mode must never use local STT")
        plan.mode = .local
        let local = try await DictationPipeline.transcribe(audio: WAV.file(pcm16: Data([0,0])), plan: plan, direct: client)
        precondition(local == "local transcript" && LocalTranscriber.shared.calls == 1)
        plan.cleanup.level = .none
        plan.cleanup.entries = [DictionaryEntry(term: "tighten", replacement: "Titan")]
        let untouched = try await DictationPipeline.clean(raw: "tighten", plan: plan.cleanup, direct: client)
        precondition(untouched.text == "Titan" && MockProvider.requests.count == 2)
        plan.cleanup.level = .medium
        plan.cleanup.entries = []
        MockProvider.chat = "bananas orbit Jupiter"
        let fallback = try await DictationPipeline.clean(raw: "hello world", plan: plan.cleanup, direct: client)
        precondition(fallback.text == "hello world", "Off-script response must preserve raw text")
        plan.mode = .direct
        plan.speech?.apiKey = nil
        plan.speechNeedsKey = true
        do {
            _ = try await DictationPipeline.transcribe(audio: Data(), plan: plan, direct: client)
            preconditionFailure("Missing credentials must fail")
        } catch DirectError.missingKey { }
        precondition(MockProvider.requests.count == 3, "No request without required credentials")
        let historyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: historyRoot) }
        let inbox = historyRoot.appendingPathComponent("inbox")
        let historyURL = historyRoot.appendingPathComponent("history.json")
        settings.historyRetention = .forever
        let history = DictationHistory(fileURL: historyURL, settings: settings)
        let entry = DictationRecord(date: Date(), engine: .direct, source: "messages",
            rawText: "hello world", finalText: "Hello world.", sttMs: 20, cleanupMs: 10, cleanupLabel: "test")
        try MessagesHistory.store(entry, directory: inbox, retention: .sessionOnly)
        precondition(!FileManager.default.fileExists(atPath: inbox.path), "Memory-only preference must not write transcripts")
        try MessagesHistory.store(entry, directory: inbox, retention: .forever)
        MessagesHistory.importPending(into: history, directory: inbox, retention: .forever)
        precondition(history.records.count == 1 && history.records[0].source == "messages")
        precondition(MessagesHistory.pending(directory: inbox, retention: .forever).isEmpty)
        let reloaded = DictationHistory(fileURL: historyURL, settings: settings)
        precondition(reloaded.records.count == 1 && reloaded.records[0].finalText == entry.finalText)
        try MessagesHistory.store(entry, directory: inbox, retention: .forever)
        MessagesHistory.importPending(into: history, directory: inbox, retention: .forever)
        precondition(history.records.count == 1, "Retry must not duplicate a dictation")
        let old = DictationRecord(date: Date().addingTimeInterval(-8 * 86400), engine: .local, source: "messages",
            rawText: "old", finalText: "old", sttMs: 0, cleanupMs: 0, cleanupLabel: "none")
        try MessagesHistory.store(old, directory: inbox, retention: .forever)
        precondition(MessagesHistory.pending(directory: inbox, retention: .sevenDays).isEmpty, "Prune expired pending history")
        try MessagesHistory.store(entry, directory: inbox, retention: .forever)
        precondition(MessagesHistory.pending(directory: inbox, retention: .sessionOnly).isEmpty)
        precondition(MessagesHistory.pending(directory: inbox, retention: .forever).isEmpty, "Turning storage off deletes pending history")
        let blockedParent = historyRoot.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedParent)
        let failingHistory = DictationHistory(fileURL: blockedParent.appendingPathComponent("history.json"), settings: settings)
        try MessagesHistory.store(entry, directory: inbox, retention: .forever)
        MessagesHistory.importPending(into: failingHistory, directory: inbox, retention: .forever)
        precondition(MessagesHistory.pending(directory: inbox, retention: .forever).count == 1, "Keep queued history when saving fails")
        print("History import, persistence, deduplication, retention, memory-only and failed-write recovery checks passed")
        print("Provider routing, settings snapshot, credentials, local/direct selection, cleanup-none and fallback checks passed")
    }
}
