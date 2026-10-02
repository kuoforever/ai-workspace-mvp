import Foundation

/// All device reads and writes share this serial queue, including command receipts.
final class DiskExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.kuoforever.aiworkspace.storage", qos: .userInitiated)
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
