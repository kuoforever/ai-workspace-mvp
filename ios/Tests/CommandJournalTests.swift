import XCTest
@testable import AIWorkspace

@MainActor final class CommandJournalTests: XCTestCase {
    private final class MemoryStore: CommandStore {
        var value: PendingCommand?
        var failWrites = false
        var failClear = false
        func pending() throws -> PendingCommand? { value }
        func savePending(_ command: PendingCommand?) throws {
            if failWrites || (failClear && command == nil) { throw CocoaError(.fileWriteOutOfSpace) }
            value = command
        }
    }
    private final class FakeAPI: WorkspaceAPI {
        var calls: [PendingCommand] = []
        var handler: (String, Data?, String?) throws -> Data
        init(_ handler: @escaping (String, Data?, String?) throws -> Data) { self.handler = handler }
        func request(_ path: String, body: Data?, key: String?) async throws -> Data {
            calls.append(PendingCommand(key: key ?? "", path: path, body: body ?? Data(), kind: "create"))
            return try handler(path, body, key)
        }
    }
    private let command = PendingCommand(key: "stable-key", path: "/reviews", body: Data("immutable".utf8), kind: "create")
    private var response: Data {
        try! Wire.encode(ReviewSnapshot(id: "saved-on-server", revision: 1, status: "waiting_model",
            input: ReviewInput(), sources: [:], questions: [], answers: [:], report: nil, error: nil))
    }

    func testLostReplyReloadsTheExactCommandFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var committed = Set<String>()
        let result = response
        let api = FakeAPI { _, _, key in
            if committed.insert(key!).inserted { throw URLError(.networkConnectionLost) }
            return result
        }
        let journal = try CommandJournal(store: DeviceStore(root: root), api: api)
        do { _ = try await journal.send(command); XCTFail("Expected lost reply") } catch is URLError { }
        let restoredStore = try DeviceStore(root: root)
        let restored = try CommandJournal(store: restoredStore, api: api)
        XCTAssertEqual(api.calls.count, 1, "Loading must not send automatically")
        XCTAssertEqual(restored.pending, command)
        let saved = try await restored.send()
        XCTAssertEqual(saved.id, "saved-on-server")
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(api.calls[0], api.calls[1])
        XCTAssertNil(try restoredStore.pending())
    }
    func testCannotReplaceAnUnconfirmedRequest() async throws {
        let store = MemoryStore(); store.value = command
        let api = FakeAPI { _, _, _ in XCTFail("Must not send"); return Data() }
        let journal = try CommandJournal(store: store, api: api)
        do {
            _ = try await journal.send(PendingCommand(key: "new", path: "/reviews", body: Data(), kind: "create"))
            XCTFail("Must preserve the original request")
        } catch is APIError { }
        XCTAssertEqual(store.value, command)
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testFailedLocalWriteNeverReachesNetwork() async throws {
        let store = MemoryStore(); store.failWrites = true
        let api = FakeAPI { _, _, _ in Data() }
        let journal = try CommandJournal(store: store, api: api)
        do { _ = try await journal.send(command); XCTFail("Expected write failure") } catch is CocoaError { }
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testConflictClearsCommandButServerFailureKeepsIt() async throws {
        for status in [409, 503] {
            let store = MemoryStore()
            let api = FakeAPI { _, _, _ in throw APIError(status: status, message: "rejected") }
            let journal = try CommandJournal(store: store, api: api)
            do { _ = try await journal.send(command); XCTFail("Expected HTTP failure") } catch is APIError { }
            XCTAssertEqual(store.value, status == 409 ? nil : command)
        }
    }
    func testInvalidSuccessBodyKeepsTheRetryIdentity() async throws {
        let store = MemoryStore()
        let api = FakeAPI { _, _, _ in Data("truncated".utf8) }
        let journal = try CommandJournal(store: store, api: api)
        do { _ = try await journal.send(command); XCTFail("Expected invalid body") } catch is DecodingError { }
        XCTAssertEqual(store.value, command)
    }
    func testClearFailureRetainsCommandForReplay() async throws {
        let store = MemoryStore(); store.failClear = true
        let result = response
        let api = FakeAPI { _, _, _ in result }
        let journal = try CommandJournal(store: store, api: api)
        do { _ = try await journal.send(command); XCTFail("Expected clear failure") } catch is CocoaError { }
        XCTAssertEqual(journal.pending, command)
        store.failClear = false
        _ = try await journal.send()
        XCTAssertEqual(api.calls[0], api.calls[1])
        XCTAssertNil(store.value)
    }
    func testCorruptJournalDoesNotBecomeAnEmptyJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        try Data("broken".utf8).write(to: root.appendingPathComponent("pending-command.json"))
        let api = FakeAPI { _, _, _ in Data() }
        XCTAssertThrowsError(try CommandJournal(store: store, api: api))
        XCTAssertTrue(api.calls.isEmpty)
    }
    func testFailedResponsePersistenceKeepsOriginalRequest() async throws {
        let store = MemoryStore()
        let result = response
        let api = FakeAPI { _, _, _ in result }
        let journal = try CommandJournal(store: store, api: api)
        do {
            _ = try await journal.send(command) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("Local persistence must finish before acknowledging the command")
        } catch is CocoaError { }
        XCTAssertEqual(journal.pending, command)
        _ = try await journal.send()
        XCTAssertEqual(api.calls[0], api.calls[1])
        XCTAssertNil(store.value)
    }
}
