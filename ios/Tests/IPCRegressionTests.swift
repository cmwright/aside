import XCTest

final class IPCRegressionTests: XCTestCase {
    func testStaleProcessingFileStillTimesOut() {
        let now = Date()
        let result = DictationResult(id: UUID(), status: .processing)
        let session = SessionState(active: true, startedAt: now - 200, expiresAt: nil,
                                   heartbeatAt: now, inputReady: true)
        XCTAssertEqual(AsideIPC.pollDecision(result: result, session: session, since: now - 181,
            now: now, sawAnswer: true, handoff: false), .timedOut)
        XCTAssertEqual(AsideIPC.pollDecision(result: result, session: nil, since: now - 10,
            now: now, sawAnswer: true, handoff: false), .unavailable)
        var final = result
        final.status = .done
        final.text = "Already finished"
        XCTAssertEqual(AsideIPC.pollDecision(result: final, session: nil, since: now - 181,
            now: now, sawAnswer: true, handoff: false), .deliver)
    }

    func testOldStopCannotAffectANewerRecording() {
        let old = UUID(), current = UUID()
        let stop = DictationCommand(action: .stop, dictationID: old)
        XCTAssertFalse(AsideIPC.targetsCurrentRecording(stop, currentID: current, currentSource: .keyboard))
        XCTAssertTrue(AsideIPC.targetsCurrentRecording(stop, currentID: old, currentSource: .keyboard))
        let legacy = DictationCommand(action: .cancel, source: .control)
        XCTAssertFalse(AsideIPC.targetsCurrentRecording(legacy, currentID: current, currentSource: .keyboard))
        XCTAssertFalse(AsideIPC.targetsCurrentRecording(stop, currentID: nil, currentSource: .keyboard))
    }

    func testCommandsWithinOneSecondKeepTheirActualOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AsideIPCStore(root: root)
        let start = DictationCommand(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            action: .start, at: Date(timeIntervalSince1970: 1000.1))
        let stop = DictationCommand(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            action: .stop, at: Date(timeIntervalSince1970: 1000.8), dictationID: start.id)
        try store.writeCommand(start)
        try store.writeCommand(stop)
        let commands = store.pendingCommands()
        XCTAssertEqual(commands.map(\.action), [.start, .stop])
        XCTAssertEqual(commands.last?.dictationID, start.id)
        XCTAssertEqual(commands.first!.at.timeIntervalSince1970, 1000.1, accuracy: 0.00001)
    }

    func testLegacyISO8601FilesRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AsideIPCStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"active":true,"startedAt":"2026-01-01T00:00:00Z","pid":1}"#.utf8).write(to: store.sessionURL)
        XCTAssertTrue(AsideIPC.isActive(store.readSession(), at: Date()))
    }

    func testHeartbeatAndMicrophoneReadinessOverrideNeverEndingSession() {
        let now = Date()
        var session = SessionState(active: true, startedAt: now, expiresAt: nil,
                                   heartbeatAt: now, inputReady: true)
        XCTAssertTrue(AsideIPC.isActive(session, at: now + 2))
        XCTAssertFalse(AsideIPC.isActive(session, at: now + 9))
        session.inputReady = false
        XCTAssertFalse(AsideIPC.isActive(session, at: now))
    }

    func testColdKeyboardHandoffSurvivesAnotherStoreInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let handoff = KeyboardHandoff(id: UUID(), at: Date())
        try AsideIPCStore(root: root).writeHandoff(handoff)
        let reloaded = AsideIPCStore(root: root)
        XCTAssertEqual(reloaded.readHandoff()?.id, handoff.id)
        reloaded.removeHandoff()
        XCTAssertNil(reloaded.readHandoff())
    }
}
