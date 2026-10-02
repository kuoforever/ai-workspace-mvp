import Foundation

enum SaveState: String { case saved = "输入已保存", saving = "正在保存输入…", failed = "输入尚未保存，仍保留在本页" }

@MainActor final class EditPersistence {
    private struct Write { let revision: Int; let work: () async throws -> Void }
    private var pending: [String: Write] = [:]
    private var failedKeys = Set<String>()
    private var revision = 0
    private var tail: Task<Void, Never>?
    private let changed: (SaveState) -> Void
    init(changed: @escaping (SaveState) -> Void) { self.changed = changed }

    func enqueue(_ key: String, work: @escaping () async throws -> Void) {
        revision += 1
        let write = Write(revision: revision, work: work)
        pending[key] = write
        failedKeys.remove(key)
        update()
        let previous = tail
        tail = Task {
            await previous?.value
            guard pending[key]?.revision == write.revision else { return }
            do { try await persist(key, write: write) }
            catch {
                if pending[key]?.revision == write.revision { failedKeys.insert(key) }
                update()
            }
        }
    }
    private func update() {
        changed(pending.isEmpty ? .saved : (failedKeys.isEmpty ? .saving : .failed))
    }
    private func persist(_ key: String, write: Write) async throws {
        try await write.work()
        if pending[key]?.revision == write.revision {
            pending.removeValue(forKey: key)
            failedKeys.remove(key)
        }
        update()
    }
    /// Flush retries the latest unsaved input; a failed flush must prevent a new submission.
    func flush() async throws {
        await tail?.value
        for (key, write) in pending {
            do { try await persist(key, write: write) }
            catch { failedKeys.insert(key); update(); throw error }
        }
        update()
    }
}
