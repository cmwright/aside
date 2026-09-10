import XCTest

/// The iPhone hand-off protocol is Foundation-only, so it is unit-tested here in the Mac
/// test target — there is no usable iOS simulator on this machine and none is needed.
/// `ios/Shared/AsideIPC.swift` is compiled into this target by `mac/project.yml`.
final class AsideIPCTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aside-ipc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store(now: @escaping @Sendable () -> Date = { Date() }) -> AsideIPCStore {
        AsideIPCStore(root: root, now: now)
    }

    // MARK: - Session validity

    func testSessionValidityAcrossExpiry() {
        let start = Date(timeIntervalSince1970: 1_000)
        let session = SessionState(active: true, startedAt: start, expiresAt: start + 900, pid: 42)

        XCTAssertTrue(AsideIPC.isActive(session, at: start))
        XCTAssertTrue(AsideIPC.isActive(session, at: start + 899))
        XCTAssertFalse(AsideIPC.isActive(session, at: start + 900), "expiry is exclusive")
        XCTAssertFalse(AsideIPC.isActive(session, at: start + 901))
    }

    func testSessionWithoutExpiryNeverExpiresAndInactiveNeverCounts() {
        let start = Date(timeIntervalSince1970: 1_000)
        let forever = SessionState(active: true, startedAt: start, expiresAt: nil, pid: 1)
        XCTAssertTrue(AsideIPC.isActive(forever, at: start + 86_400))

        let ended = SessionState(active: false, startedAt: start, expiresAt: nil, pid: 1)
        XCTAssertFalse(AsideIPC.isActive(ended, at: start))
        XCTAssertFalse(AsideIPC.isActive(nil, at: start), "a missing file is no session")
    }

    func testActiveSessionReadsThroughTheClock() throws {
        let start = Date(timeIntervalSince1970: 5_000)
        let clockValue = LockedDate(start)
        let ipc = store { clockValue.value }

        XCTAssertNil(ipc.activeSession(), "nothing written yet")
        try ipc.writeSession(SessionState(active: true, startedAt: start, expiresAt: start + 300, pid: 7))
        XCTAssertEqual(ipc.activeSession()?.pid, 7)

        clockValue.value = start + 301
        XCTAssertNil(ipc.activeSession(), "expired on the wall clock alone, with no rewrite")
        XCTAssertNotNil(ipc.readSession(), "the file itself is still there")

        clockValue.value = start
        try ipc.endSession()
        XCTAssertNil(ipc.activeSession())
        XCTAssertEqual(ipc.readSession()?.startedAt, start, "endSession keeps the timestamps")
    }

    // MARK: - Round trip

    func testCommandAndResultRoundTripThroughTheDirectory() throws {
        let keyboard = store()
        let app = store()

        let command = DictationCommand(action: .start, at: Date(timeIntervalSince1970: 10),
                                       contextBefore: "hello there")
        try keyboard.writeCommand(command)

        let seen = app.pendingCommands()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first, command, "dates survive the ISO-8601 encoding")

        try app.writeResult(DictationResult(id: command.id, status: .recording))
        XCTAssertEqual(keyboard.readResult(id: command.id)?.status, .recording)

        try app.writeResult(DictationResult(
            id: command.id, status: .done, text: "Good morning.", rawText: "good morning",
            engine: "parakeet", cleanup: "Apple on-device model", sttMs: 320, cleanupMs: 640))
        let done = try XCTUnwrap(keyboard.readResult(id: command.id))
        XCTAssertEqual(done.status, .done)
        XCTAssertTrue(done.isFinal)
        XCTAssertEqual(done.text, "Good morning.")
        XCTAssertEqual(done.rawText, "good morning")
        XCTAssertEqual(done.sttMs, 320)
        XCTAssertEqual(done.cleanupMs, 640)
        XCTAssertNil(done.error)

        app.removeCommand(id: command.id)
        XCTAssertTrue(app.pendingCommands().isEmpty)
        keyboard.removeResult(id: command.id)
        XCTAssertNil(keyboard.readResult(id: command.id))
    }

    func testResultFilesAreJSONOnDiskUnderTheCommandID() throws {
        let ipc = store()
        let id = UUID()
        try ipc.writeResult(DictationResult(id: id, status: .failed, error: "no microphone"))
        let url = ipc.resultsDirectory.appendingPathComponent("\(id.uuidString).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["status"] as? String, "failed")
        XCTAssertEqual(object?["error"] as? String, "no microphone")
    }

    func testUnreadableFilesAreIgnoredRatherThanThrowing() throws {
        let ipc = store()
        try FileManager.default.createDirectory(at: ipc.commandsDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: ipc.commandsDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        try ipc.writeCommand(DictationCommand(action: .stop))
        XCTAssertEqual(ipc.pendingCommands().count, 1, "the junk file is skipped, the good one still arrives")
    }

    // MARK: - Ordering

    func testPendingCommandsComeBackOldestFirst() throws {
        let ipc = store()
        let base = Date(timeIntervalSince1970: 100)
        let third = DictationCommand(action: .cancel, at: base + 2)
        let first = DictationCommand(action: .start, at: base)
        let second = DictationCommand(action: .stop, at: base + 1)
        try ipc.writeCommand(third)
        try ipc.writeCommand(first)
        try ipc.writeCommand(second)

        XCTAssertEqual(ipc.pendingCommands().map(\.action), [.start, .stop, .cancel])
    }

    func testOrderingIsStableForCommandsWithTheSameTimestamp() {
        let at = Date(timeIntervalSince1970: 100)
        let a = DictationCommand(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, action: .start, at: at)
        let b = DictationCommand(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, action: .stop, at: at)
        XCTAssertEqual(AsideIPC.ordered([b, a]).map(\.id), [a.id, b.id])
        XCTAssertEqual(AsideIPC.ordered([a, b]).map(\.id), [a.id, b.id])
    }

    // MARK: - Housekeeping

    func testPurgeDropsOnlyStaleCommandsAndResults() throws {
        let ipc = store()
        let old = DictationCommand(action: .start, at: Date(timeIntervalSince1970: 0))
        let fresh = DictationCommand(action: .stop, at: Date())
        try ipc.writeCommand(old)
        try ipc.writeResult(DictationResult(id: old.id, status: .done, text: "secret"))
        try ipc.writeCommand(fresh)

        // purge works off file modification dates, so age the two old files by hand.
        let ancient = Date().addingTimeInterval(-3_600)
        for url in [ipc.commandsDirectory.appendingPathComponent("\(old.id.uuidString).json"),
                    ipc.resultsDirectory.appendingPathComponent("\(old.id.uuidString).json")] {
            try FileManager.default.setAttributes([.modificationDate: ancient], ofItemAtPath: url.path)
        }

        XCTAssertEqual(ipc.purge(olderThan: 600), 2)
        XCTAssertEqual(ipc.pendingCommands().map(\.id), [fresh.id])
        XCTAssertNil(ipc.readResult(id: old.id), "a stale transcript does not sit in the container")
        XCTAssertEqual(ipc.purge(olderThan: 600), 0, "purge is idempotent")
    }

    func testPurgeOnAnEmptyContainerIsHarmless() {
        XCTAssertEqual(store().purge(), 0)
    }

    func testRemoveAllClearsTheContainer() throws {
        let ipc = store()
        try ipc.writeSession(SessionState(active: true, startedAt: Date(), expiresAt: nil, pid: 1))
        try ipc.writeCommand(DictationCommand(action: .start))
        ipc.removeAll()
        XCTAssertNil(ipc.readSession())
        XCTAssertTrue(ipc.pendingCommands().isEmpty)
    }

    // MARK: - Leading space

    // MARK: - Control Center

    func testCommandWithoutSourceDecodesAsKeyboard() throws {
        let json = #"{"action":"start","at":"2026-01-01T00:00:00Z","id":"6B29FC40-CA47-1067-B31D-00DD010662DA"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let command = try decoder.decode(DictationCommand.self, from: Data(json.utf8))
        XCTAssertNil(command.source)
        XCTAssertFalse(command.isFromControl)
    }

    func testControlCommandRoundTripsThroughTheStore() throws {
        let store = store()
        try store.writeCommand(DictationCommand(action: .stop, source: .control))
        let pending = store.pendingCommands()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.source, .control)
        XCTAssertTrue(pending.first?.isFromControl == true)
    }

    func testControlStateIsWrittenReadAndRemoved() throws {
        let store = store()
        XCTAssertNil(store.readControlState())
        try store.writeControlState(ControlState(recording: true))
        XCTAssertEqual(store.readControlState()?.recording, true)
        store.removeAll()
        XCTAssertNil(store.readControlState())
    }

    func testLeadingSpaceRuleMatchesTheMacInserter() {
        // Same table as the Mac's TextInserter.needsLeadingSpace, driven by context text.
        XCTAssertTrue(AsideIPC.needsLeadingSpace(contextBefore: "hello", text: "world"))
        XCTAssertTrue(AsideIPC.needsLeadingSpace(contextBefore: "chapter 7", text: "begins"))
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: "hello ", text: "world"), "already spaced")
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: "hello.", text: "World"), "punctuation before")
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: "hello", text: "3 apples"), "digit first")
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: "hello", text: "…and"), "not a letter")
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: nil, text: "world"), "no context, no guess")
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: "", text: "world"))
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: "hello", text: ""))
        XCTAssertFalse(AsideIPC.needsLeadingSpace(contextBefore: "line\n", text: "next"))
    }

    func testContextIsTrimmedToTheLastFortyCharacters() {
        let long = String(repeating: "a", count: 100) + "end"
        let trimmed = AsideIPC.trimContext(long)
        XCTAssertEqual(trimmed?.count, AsideIPC.contextBeforeLimit)
        XCTAssertTrue(trimmed?.hasSuffix("end") == true, "the tail is what matters")
        XCTAssertNil(AsideIPC.trimContext(nil))
        XCTAssertNil(AsideIPC.trimContext(""))
        XCTAssertEqual(AsideIPC.trimContext("hi"), "hi")
    }
}

/// A settable clock the injected `now` closure can read from any thread.
private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) { stored = value }

    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
