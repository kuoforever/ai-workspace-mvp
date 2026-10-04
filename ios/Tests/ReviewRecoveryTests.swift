import XCTest
@testable import AIWorkspace

@MainActor final class ReviewRecoveryTests: XCTestCase {
    private final class API: WorkspaceAPI {
        var value: ReviewSnapshot
        var writes = 0
        init(_ value: ReviewSnapshot) { self.value = value }
        func request(_ path: String, body: Data?, key: String?) async throws -> Data {
            if body != nil { writes += 1 }
            if path == "/catalog" { return Data("{\"checks\":[]}".utf8) }
            if path == "/reviews" && body == nil { return Data("[]".utf8) }
            return try Wire.encode(value)
        }
    }
    private func snapshot(_ id: String, _ revision: Int, _ status: String) -> ReviewSnapshot {
        ReviewSnapshot(id: id, revision: revision, status: status,
            input: ReviewInput(title: id, design: "Query the payment status before retrying."),
            sources: [:], questions: [Question(id: "q1", text: "How are timeouts handled?")],
            answers: [:], report: nil, error: nil)
    }

    func testWaitingInputUpdatesFromAnotherDeviceAndKeepsLocalAnswers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let api = API(snapshot("shared", 2, "waiting_input"))
        try store.saveReview(api.value)
        let model = WorkspaceModel(api: api, store: store)
        await model.open("shared")
        model.editAnswer("q1", "My latest unsent answer")
        XCTAssertTrue(model.shouldPoll)
        api.value = snapshot("shared", 3, "completed")
        if model.shouldPoll { await model.refresh() }
        XCTAssertEqual(model.review?.status, "completed")
        XCTAssertEqual(model.answers["q1"], "My latest unsent answer")
        XCTAssertEqual(try store.answers("shared")["q1"], "My latest unsent answer")
        XCTAssertFalse(model.shouldPoll)
    }

    func testRefreshRejectsAnotherReviewAndCannotRollBackNewerCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        try store.saveReview(snapshot("selected", 3, "completed"))
        let api = API(snapshot("selected", 2, "waiting_input"))
        let model = WorkspaceModel(api: api, store: store)
        await model.open("selected")
        XCTAssertEqual(model.review?.revision, 3)
        XCTAssertEqual(try store.cachedReview("selected")?.status, "completed")
        api.value = snapshot("wrong-review", 4, "completed")
        await model.refresh()
        XCTAssertEqual(model.review?.id, "selected")
        XCTAssertEqual(model.review?.revision, 3)
        XCTAssertNotNil(model.error)
        XCTAssertNil(try store.cachedReview("wrong-review"))
    }

    func testStoreCannotOverwriteANewerRevisionAcrossInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        try store.saveReview(snapshot("same", 3, "completed"))
        try DeviceStore(root: root).saveReview(snapshot("same", 2, "waiting_input"))
        XCTAssertEqual(try DeviceStore(root: root).cachedReview("same")?.revision, 3)
        XCTAssertEqual(try DeviceStore(root: root).cachedReview()?.status, "completed")
    }

    func testTypingDuringAnAutomaticPollKeepsTheNewestAnswer() async throws {
        final class DelayedAPI: WorkspaceAPI {
            let value: ReviewSnapshot
            var delay = false
            var continuation: CheckedContinuation<Data, Error>?
            init(_ value: ReviewSnapshot) { self.value = value }
            func request(_ path: String, body: Data?, key: String?) async throws -> Data {
                if path == "/catalog" { return Data("{\"checks\":[]}".utf8) }
                if delay { return try await withCheckedThrowingContinuation { continuation = $0 } }
                return try Wire.encode(value)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let api = DelayedAPI(snapshot("typing", 2, "waiting_input"))
        try store.saveReview(api.value)
        let model = WorkspaceModel(api: api, store: store)
        await model.open("typing")
        model.editAnswer("q1", "first")
        api.delay = true
        let poll = Task { await model.refresh(autoRefresh: true) }
        for _ in 0..<1000 {
            if api.continuation != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(api.continuation)
        XCTAssertTrue(model.canEditAnswers)
        XCTAssertFalse(model.editable)
        model.editAnswer("q1", "newest while the poll is waiting")
        api.continuation?.resume(returning: try Wire.encode(api.value))
        api.continuation = nil
        await poll.value
        await model.retrySave()
        XCTAssertEqual(model.answers["q1"], "newest while the poll is waiting")
        XCTAssertEqual(try store.answers("typing")["q1"], model.answers["q1"])
        XCTAssertFalse(model.refreshing)
    }

    func testReloadAfterJournalRepairPreservesTheOriginalCommandWithoutResending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        try Data("{broken".utf8).write(to: root.appendingPathComponent("pending-command.json"))
        let api = API(snapshot("unused", 1, "waiting_model"))
        let model = WorkspaceModel(api: api, store: store)
        await model.waitUntilLoaded()
        XCTAssertNotNil(model.startupError)
        XCTAssertFalse(model.editable)
        let command = PendingCommand(key: "keep", path: "/reviews", body: Data("original".utf8), kind: "create")
        try store.savePending(command)
        await model.reloadLocalData()
        XCTAssertNil(model.startupError)
        XCTAssertEqual(model.pending, command)
        XCTAssertEqual(try store.pending(), command)
        XCTAssertEqual(api.writes, 0)
        XCTAssertFalse(model.editable)
    }

    func testDiskCancellationDoesNotReturnANoncooperativeLateResult() async throws {
        let (started, signal) = AsyncStream.makeStream(of: Bool.self)
        let release = DispatchSemaphore(value: 0)
        let disk = DiskExecutor()
        let operation = Task {
            try await disk.run {
                signal.yield(true)
                _ = release.wait(timeout: .now() + 5)
                return "late result"
            }
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        operation.cancel(); release.signal()
        do { _ = try await operation.value; XCTFail("Cancelled storage work must not publish a result") }
        catch is CancellationError { }
    }
}
