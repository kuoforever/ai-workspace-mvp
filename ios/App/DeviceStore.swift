import Foundation

protocol CommandStore {
    func pending() throws -> PendingCommand?
    func savePending(_ command: PendingCommand?) throws
}

final class DeviceStore: CommandStore {
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
    private func answerFile(_ id: String) -> String {
        // Server identifiers never become filesystem path components verbatim.
        "answers-" + Data(id.utf8).map { String(format: "%02x", $0) }.joined() + ".json"
    }
}
