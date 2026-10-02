import Foundation

@MainActor final class CommandJournal {
    private let store: CommandStore
    private let api: WorkspaceAPI
    private let disk: DiskExecutor
    private(set) var pending: PendingCommand?
    private var sending = false

    init(store: CommandStore, api: WorkspaceAPI, disk: DiskExecutor = DiskExecutor()) async throws {
        self.store = store
        self.api = api
        self.disk = disk
        pending = try await disk.run { try store.pending() } // Corruption is not an empty journal.
    }
    func send(_ candidate: PendingCommand? = nil, accept: (ReviewSnapshot) async throws -> Void = { _ in }) async throws -> ReviewSnapshot {
        guard !sending else { throw APIError(status: 0, message: "正在确认上次提交。") }
        guard pending == nil || candidate == nil || pending == candidate else {
            throw APIError(status: 0, message: "请先重试尚未确认的原提交。")
        }
        guard let command = pending ?? candidate else {
            throw APIError(status: 0, message: "没有待确认的提交。")
        }
        sending = true
        defer { sending = false }
        let store = self.store
        try await disk.run { try store.savePending(command) } // Persist before sending.
        pending = command
        let response: Data
        do { response = try await api.request(command.path, body: command.body, key: command.key) }
        catch let error as APIError {
            if (400..<500).contains(error.status) {
                try await disk.run { try store.savePending(nil) }
                pending = nil
            }
            throw error
        }
        try Task.checkCancellation()
        let review = try Wire.decode(ReviewSnapshot.self, response)
        // The local response must be saved before its retry identity is cleared.
        try await accept(review)
        // Unknown outcomes, cancellation and invalid responses keep the exact command.
        try await disk.run { try store.savePending(nil) }
        pending = nil
        return review
    }
}
