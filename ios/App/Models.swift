import Foundation

struct CheckCard: Codable, Identifiable { let id: String; let question: String }
struct Catalog: Decodable { let checks: [CheckCard] }
struct ServerConfig: Decodable { let modes: [String] }
func assistantPrompt(_ id: String) -> String {
    "请通过 swe-workspace 读取评审 \(id) 的最新上下文，按选定检查项继续评审。需要澄清时提交问题；材料充分时提交带原文引用的报告。"
}
struct ReviewSummary: Codable, Identifiable {
    let id: String
    let title: String
    let status: String
    let mode: String
}
struct ReviewInput: Codable, Equatable {
    var title = ""
    var design = ""
    var mode = "mcp"
    var checkIDs = ["CON-01", "FAIL-01"]
    var recordID = "ios"
    enum CodingKeys: String, CodingKey {
        case title, design, mode
        case checkIDs = "check_ids", recordID = "workbench_record_id"
    }
}
struct Source: Codable { let title: String; let text: String; let path: String; let sha256: String }
struct Citation: Codable {
    let sourceID: String
    let quote: String
    enum CodingKeys: String, CodingKey { case sourceID = "source_id", quote }
}
struct Finding: Codable, Identifiable {
    let checkID: String
    let verdict: String
    let explanation: String
    let recommendation: String
    let citations: [Citation]
    var id: String { checkID }
    enum CodingKeys: String, CodingKey {
        case checkID = "check_id", verdict, explanation, recommendation, citations
    }
}
struct Report: Codable { let summary: String; let findings: [Finding] }
struct Question: Codable, Identifiable { let id: String; let text: String }
struct ReviewSnapshot: Codable {
    let id: String
    let revision: Int
    let status: String
    let input: ReviewInput
    let sources: [String: Source]
    let questions: [Question]
    let answers: [String: String]
    let report: Report?
    let error: String?
}
struct AnswerCommand: Encodable { let revision: Int; let answers: [String: String] }
struct PendingCommand: Codable, Equatable {
    let key: String
    let path: String
    let body: Data
    let kind: String
    var reviewID: String? = nil
}

func statusLabel(_ value: String) -> String {
    ["waiting_model": "等待助手", "waiting_input": "等待补充", "completed": "已完成",
     "running": "正在处理", "failed": "失败", "interrupted": "已中断"][value] ?? value
}
func verdictLabel(_ value: String) -> String {
    ["supported": "有材料支持", "risk": "存在风险", "unknown": "信息不足",
     "not_applicable": "不适用"][value] ?? value
}

enum Wire {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
