import XCTest
@testable import AIWorkspace

@MainActor final class ConnectionTests: XCTestCase {
    private final class API: WorkspaceAPI {
        var calls: [(String, Data?)] = []
        var failure: Error?
        var response = Data("{\"modes\":[\"mcp\"]}".utf8)
        func request(_ path: String, body: Data?, key: String?) async throws -> Data {
            calls.append((path, body))
            if let failure { throw failure }
            return response
        }
    }
    func testCheckOnlyReadsAndPreservesPendingWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let command = PendingCommand(key: "keep", path: "/reviews", body: Data("original".utf8), kind: "create")
        try store.savePending(command)
        let api = API()
        let model = WorkspaceModel(api: api, store: store)
        api.failure = URLError(.cannotConnectToHost)
        await model.checkConnection()
        XCTAssertEqual(model.connection, .offline)
        api.failure = nil
        await model.checkConnection()
        XCTAssertEqual(model.connection, .connected)
        XCTAssertNil(model.error)
        XCTAssertEqual(try store.pending(), command)
        XCTAssertTrue(api.calls.allSatisfy { $0.0 == "/config" && $0.1 == nil })
        api.response = Data("unexpected".utf8)
        await model.checkConnection()
        XCTAssertEqual(model.connection, .unavailable)
    }
    func testServerRejectionIsNotAnOfflineConnection() async throws {
        let api = API()
        var states: [ConnectionState] = []
        let observed = ObservedWorkspaceAPI(base: api) { states.append($0) }
        for status in [409, 503] {
            api.failure = APIError(status: status, message: "rejected")
            do { _ = try await observed.get("/config"); XCTFail("Expected rejection") } catch is APIError { }
        }
        XCTAssertEqual(states, [.connected, .unavailable])
        api.failure = URLError(.cancelled)
        do { _ = try await observed.get("/config") } catch is URLError { }
        XCTAssertEqual(states, [.connected, .unavailable])
    }
}
