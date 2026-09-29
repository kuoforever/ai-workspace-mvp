import Foundation

@MainActor final class CommandJournal {
    private let store: CommandStore
    private let api: WorkspaceAPI
    private(set) var pending: PendingCommand?
    private var sending = false

    init(store: CommandStore, api: WorkspaceAPI) throws {
        self.store = store
        self.api = api
        pending = try store.pending() // Corruption is not treated as an empty journal.
    }
    func send(_ candidate: PendingCommand? = nil) async throws -> ReviewSnapshot {
        guard !sending else { throw APIError(status: 0, message: "正在确认上次提交。") }
        guard pending == nil || candidate == nil || pending == candidate else {
            throw APIError(status: 0, message: "请先重试尚未确认的原提交。")
        }
        guard let command = pending ?? candidate else {
            throw APIError(status: 0, message: "没有待确认的提交。")
        }
        sending = true
        defer { sending = false }
        try store.savePending(command) // A failed local write must not reach the network.
        pending = command
        let response: Data
        do { response = try await api.request(command.path, body: command.body, key: command.key) }
        catch let error as APIError {
            if (400..<500).contains(error.status) {
                try store.savePending(nil)
                pending = nil
            }
            throw error
        }
        let review = try Wire.decode(ReviewSnapshot.self, response)
        // Unknown outcomes, cancellation and invalid responses keep the exact command.
        try store.savePending(nil)
        pending = nil
        return review
    }
}
