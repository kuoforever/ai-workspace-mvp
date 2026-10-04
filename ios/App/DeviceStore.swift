import Foundation

protocol CommandStore: Sendable {
    func pending() throws -> PendingCommand?
    func savePending(_ command: PendingCommand?) throws
}

// Production callers access this store only through their shared DiskExecutor.
final class DeviceStore: CommandStore, @unchecked Sendable {
    let root: URL
    init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("AIWorkspace")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var directory = self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Wire.decode(T?.self, Data(contentsOf: file))
    }
    func save<T: Encodable>(_ name: String, value: T) throws {
        let file = root.appendingPathComponent(name)
        try Wire.encode(value).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func pending() throws -> PendingCommand? { try load("pending-command.json", as: PendingCommand.self) }
    func savePending(_ command: PendingCommand?) throws {
        // Persist JSON null through the same atomic replacement path as a command.
        try save("pending-command.json", value: command)
    }
    func answers(_ id: String) throws -> [String: String] {
        try load(answerFile(id), as: [String: String].self) ?? [:]
    }
    func saveAnswers(_ id: String, _ answers: [String: String]) throws {
        try save(answerFile(id), value: answers)
    }
    func cachedReview(_ id: String? = nil) throws -> ReviewSnapshot? {
        if let id, let saved = try load(reviewFile(id), as: ReviewSnapshot.self) { return saved }
        let latest = try load("review.json", as: ReviewSnapshot.self)
        return id == nil || latest?.id == id ? latest : nil
    }
    func savedReviews() throws -> [ReviewSnapshot] {
        let ids = try load("saved-review-ids.json", as: [String].self) ?? []
        var reviews = try ids.map { id -> ReviewSnapshot in
            guard let review = try load(reviewFile(id), as: ReviewSnapshot.self) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return review
        }
        if let legacy = try cachedReview(), !reviews.contains(where: { $0.id == legacy.id }) { reviews.insert(legacy, at: 0) }
        return reviews
    }
    func saveReview(_ review: ReviewSnapshot) throws {
        let previous = try savedReviews()
        let accepted = previous.first { $0.id == review.id && $0.revision > review.revision } ?? review
        let kept = Array(([accepted] + previous.filter { $0.id != review.id }).prefix(20))
        // Write bodies before publishing the index. A partial write can be retried safely.
        for value in kept where value.id == review.id || !FileManager.default.fileExists(atPath: root.appendingPathComponent(reviewFile(value.id)).path) {
            try save(reviewFile(value.id), value: value)
        }
        try save("review.json", value: accepted)
        try save("saved-review-ids.json", value: kept.map(\.id))
        for value in previous where !kept.contains(where: { $0.id == value.id }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(reviewFile(value.id)))
        }
    }
    private func reviewFile(_ id: String) -> String {
        "review-" + Data(id.utf8).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    private func answerFile(_ id: String) -> String {
        // Server identifiers never become filesystem path components verbatim.
        "answers-" + Data(id.utf8).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
