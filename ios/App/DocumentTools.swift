import Foundation

struct ImportedDocument: Sendable { let name: String; let text: String }
struct SourceExcerpt: Sendable {
    let before: String; let quote: String; let after: String
    let firstLine: Int; let lastLine: Int
}
enum DocumentImport {
    static let maximumBytes = 32768
    static func parse(name: String, data: Data) throws -> ImportedDocument {
        guard ["txt", "md", "markdown"].contains((name as NSString).pathExtension.lowercased()) else {
            throw APIError(status: 0, message: "请选择 UTF-8 编码的 .txt 或 Markdown 文件。")
        }
        guard data.count <= maximumBytes else {
            throw APIError(status: 0, message: "文件过大，请选择不超过 8000 字符的材料。")
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw APIError(status: 0, message: "文件不是有效的 UTF-8 文本，原草稿已保留。")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard !text.contains("\0"), (10...8000).contains(text.unicodeScalars.count) else {
            throw APIError(status: 0, message: "材料需要 10–8000 字符且不含非文本内容，原草稿已保留。")
        }
        return ImportedDocument(name: name, text: text)
    }
    static func read(_ url: URL) throws -> ImportedDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(4096, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw APIError(status: 0, message: "文件过大，请选择不超过 8000 字符的材料。")
            }
        }
        return try parse(name: url.lastPathComponent, data: data)
    }
}

func sourceExcerpt(_ text: String, quote: String) -> SourceExcerpt? {
    guard !quote.isEmpty else { return nil }
    let raw = text as NSString
    let range = raw.range(of: quote, options: .literal)
    guard range.location != NSNotFound else { return nil }
    let before = raw.substring(to: range.location).components(separatedBy: "\n")
    let after = raw.substring(from: NSMaxRange(range)).components(separatedBy: "\n")
    return SourceExcerpt(before: before.suffix(3).joined(separator: "\n"), quote: quote,
        after: after.prefix(3).joined(separator: "\n"), firstLine: before.count,
        lastLine: before.count + quote.components(separatedBy: "\n").count - 1)
}
extension ReviewSnapshot {
    var summary: ReviewSummary { ReviewSummary(id: id, title: input.title, status: status, mode: input.mode) }
    var markdown: String {
        var lines = ["# " + input.title, "", "模式：\(input.mode) · 状态：\(status)",
            "评审：\(id) · 版本：\(revision)", "",
            "引用文本经服务校验；语义仍需人工判断。代码与实验未执行。"]
        if input.mode == "scripted" { lines += ["", "**离线模拟数据，未经模型评审。**"] }
        lines += ["", "## 设计快照", "", input.design]
        if let report {
            lines += ["", "## 评审", "", report.summary]
            for finding in report.findings {
                lines += ["", "### \(finding.checkID) · \(finding.verdict)", "", finding.explanation, "", finding.recommendation]
                for citation in finding.citations {
                    if let source = sources[citation.sourceID] {
                        lines += ["", "来源 \(citation.sourceID) · \(source.path) · SHA-256 \(source.sha256)", ""]
                        lines += citation.quote.components(separatedBy: "\n").map { "> " + $0 }
                    }
                }
            }
        }
        if !questions.isEmpty {
            lines += ["", "## 澄清记录"]
            for question in questions { lines += ["", question.text, "", answers[question.id] ?? "待回答"] }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
