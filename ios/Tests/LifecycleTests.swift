import XCTest
@testable import AIWorkspace

@MainActor final class LifecycleTests: XCTestCase {
    private final class DelayedAPI: WorkspaceAPI {
        var continuation: CheckedContinuation<Data, Error>?
        var calls: [(String, Data?, String?)] = []
        var delay = true
        let response: Data
        init(response: Data) { self.response = response }
        func request(_ path: String, body: Data?, key: String?) async throws -> Data {
            calls.append((path, body, key))
            if path == "/catalog" { return Data("{\"checks\":[]}".utf8) }
            if delay { return try await withCheckedThrowingContinuation { continuation = $0 } }
            return response
        }
        func finish() { continuation?.resume(returning: response); continuation = nil }
        func fail(_ error: Error) { continuation?.resume(throwing: error); continuation = nil }
    }

    private func waitForRequest(_ api: DelayedAPI) async throws {
        for _ in 0..<1000 {
            if api.continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The request never started")
        throw URLError(.timedOut)
    }

    func testCancelledRefreshDiscardsANoncooperativeLateResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let rows = [ReviewSummary(id: "late", title: "late result", status: "completed", mode: "scripted")]
        let api = DelayedAPI(response: try Wire.encode(rows))
        let model = WorkspaceModel(api: api, store: store)
        await model.waitUntilLoaded()
        let refresh = Task { await model.refresh() }
        try await waitForRequest(api)
        refresh.cancel()
        api.finish()
        await refresh.value
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)
        XCTAssertNil(try store.load("list.json", as: [ReviewSummary].self))
        XCTAssertEqual(model.connection, .connected)
        api.delay = false
        await model.refresh()
        XCTAssertEqual(model.rows.first?.id, "late")
    }

    func testCancelledSubmissionKeepsTheOriginalCommandUntilRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let result = ReviewSnapshot(id: "accepted", revision: 1, status: "waiting_model",
            input: ReviewInput(), sources: [:], questions: [], answers: [:], report: nil, error: nil)
        let api = DelayedAPI(response: try Wire.encode(result))
        let journal = try await CommandJournal(store: store, api: api)
        let original = PendingCommand(key: "same-key", path: "/reviews", body: Data("original".utf8), kind: "create")
        let submission = Task { try await journal.send(original) }
        try await waitForRequest(api)
        submission.cancel()
        api.finish()
        do { _ = try await submission.value; XCTFail("Cancellation must be preserved") }
        catch is CancellationError { }
        XCTAssertEqual(journal.pending, original)
        XCTAssertEqual(try store.pending(), original)
        api.delay = false
        _ = try await journal.send()
        XCTAssertEqual(api.calls.count, 2)
        XCTAssertTrue(api.calls.allSatisfy { $0.1 == original.body && $0.2 == original.key })
        XCTAssertNil(try store.pending())
    }

    func testCancelledRequestsDiscardLateConnectionErrors() async throws {
        for failure: Error in [APIError(status: 503, message: "late failure"), URLError(.networkConnectionLost)] {
            let api = DelayedAPI(response: Data())
            var updates: [ConnectionState] = []
            let observed = ObservedWorkspaceAPI(base: api) { updates.append($0) }
            let request = Task { try await observed.get("/reviews") }
            try await waitForRequest(api)
            request.cancel(); api.fail(failure)
            do { _ = try await request.value; XCTFail("Cancellation must take precedence") }
            catch is CancellationError { }
            XCTAssertTrue(updates.isEmpty)
        }
    }

    func testCancelledSubmissionDoesNotClearAReceiptOnLateRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let api = DelayedAPI(response: Data())
        let journal = try await CommandJournal(store: store, api: api)
        let original = PendingCommand(key: "keep-late", path: "/reviews", body: Data("original".utf8), kind: "create")
        let submission = Task { try await journal.send(original) }
        try await waitForRequest(api)
        submission.cancel(); api.fail(APIError(status: 409, message: "late conflict"))
        do { _ = try await submission.value; XCTFail("Cancellation must take precedence") }
        catch is CancellationError { }
        XCTAssertEqual(journal.pending, original)
        XCTAssertEqual(try store.pending(), original)
    }
}
