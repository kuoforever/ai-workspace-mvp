import Foundation

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

@MainActor protocol WorkspaceAPI {
    func request(_ path: String, body: Data?, key: String?) async throws -> Data
}
extension WorkspaceAPI {
    func get(_ path: String) async throws -> Data { try await request(path, body: nil, key: nil) }
}

enum ConnectionState: String {
    case unknown = "尚未检查连接", checking = "正在检查连接", connected = "工作台已连接"
    case offline = "工作台未连接", unavailable = "工作台暂不可用"
}

@MainActor final class ObservedWorkspaceAPI: WorkspaceAPI {
    private let base: WorkspaceAPI
    private let update: (ConnectionState) -> Void
    init(base: WorkspaceAPI, update: @escaping (ConnectionState) -> Void) {
        self.base = base; self.update = update
    }
    func request(_ path: String, body: Data?, key: String?) async throws -> Data {
        do {
            let result = try await base.request(path, body: body, key: key)
            try Task.checkCancellation()
            update(.connected)
            return result
        } catch let failure as APIError {
            update(failure.status >= 500 ? .unavailable : .connected)
            throw failure
        } catch let failure as URLError {
            if failure.code != .cancelled { update(.offline) }
            throw failure
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class LocalWorkspaceAPI: WorkspaceAPI {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    func request(_ path: String, body: Data?, key: String?) async throws -> Data {
        guard path.hasPrefix("/"), !path.contains(".."),
              let url = URL(string: "http://localhost:8765/api" + path), url.host == "localhost" else {
            throw APIError(status: 0, message: "无效的工作台路径。")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json, text/markdown", forHTTPHeaderField: "Accept")
        if let body {
            guard let key, !key.isEmpty else { throw APIError(status: 0, message: "缺少请求标识。") }
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError(status: response.statusCode, message: detail ?? "工作台返回 HTTP \(response.statusCode)")
        }
        return data
    }
}
