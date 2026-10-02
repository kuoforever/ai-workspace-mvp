import XCTest
@testable import AIWorkspace

@MainActor final class MobileDocumentsTests: XCTestCase {
    private final class API: WorkspaceAPI {
        var writes = 0
        var calls = 0
        func request(_ path: String, body: Data?, key: String?) async throws -> Data {
            calls += 1
            if body != nil { writes += 1 }
            throw URLError(.notConnectedToInternet)
        }
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func snapshot(_ id: String) -> ReviewSnapshot {
        ReviewSnapshot(id: id, revision: 3, status: "completed",
            input: ReviewInput(title: "报告 " + id, design: "订单失败后先查询状态，再决定重试。"),
            sources: ["input": Source(title: "设计", text: "订单失败后先查询状态，再决定重试。", path: "input.txt", sha256: "digest")],
            questions: [], answers: [:],
            report: Report(summary: "报告结论 " + id, findings: [
                Finding(checkID: "CON-01", verdict: "risk", explanation: "解释", recommendation: "建议",
                    citations: [Citation(sourceID: "input", quote: "先查询状态")])
            ]), error: nil)
    }
    func testStrictUtf8ImportPreservesBomMarkdownAndLineEndings() throws {
        let text = "# 订单设计\r\n\r\n失败后先查询状态，不重复创建订单。😀"
        let imported = try DocumentImport.parse(name: "orders.MD", data: Data(("\u{FEFF}" + text).utf8))
        XCTAssertEqual(imported.text, text)
        for data in [Data([0xC3, 0x28]), Data("short".utf8), Data(("long enough\0").utf8),
                     Data(String(repeating: "a", count: 8001).utf8),
                     Data(repeating: 97, count: DocumentImport.maximumBytes + 1)] {
            XCTAssertThrowsError(try DocumentImport.parse(name: "design.txt", data: data))
        }
        XCTAssertThrowsError(try DocumentImport.parse(name: "design.pdf", data: Data(text.utf8)))
        XCTAssertEqual(try DocumentImport.parse(name: "emoji.md", data: Data(String(repeating: "😀", count: 8000).utf8)).text.unicodeScalars.count, 8000)
    }
    func testQuoteLocationUsesExactUnicodeAndCrLfSource() throws {
        let text = "标题😀\r\n前文\r\n支付超时\r\n先查询状态\r\n后文\r\n结束"
        let excerpt = try XCTUnwrap(sourceExcerpt(text, quote: "支付超时\r\n先查询状态"))
        XCTAssertEqual(excerpt.firstLine, 3)
        XCTAssertEqual(excerpt.lastLine, 4)
        XCTAssertTrue(excerpt.before.contains("前文") && excerpt.after.contains("后文"))
        XCTAssertNil(sourceExcerpt(text, quote: "不存在的片段"))
    }
    func testDiskExecutorDoesNotRunOnMainThread() async throws {
        let onMain = try await DiskExecutor().run { Thread.isMainThread }
        XCTAssertFalse(onMain)
    }
    func testFailedDraftSaveKeepsInputAndPreventsSubmission() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let api = API()
        let model = WorkspaceModel(api: api, store: store)
        await model.waitUntilLoaded()
        let blocked = root.appendingPathComponent("draft.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        var input = ReviewInput()
        input.title = "最新输入"; input.design = "订单超时后先查询状态，再决定重试。"
        model.edit(input)
        XCTAssertEqual(model.draft, input, "Typing must update the UI before disk acknowledgement")
        await model.create()
        XCTAssertEqual(model.saveState, .failed)
        XCTAssertEqual(model.draft, input)
        XCTAssertEqual(api.writes, 0)
        try FileManager.default.removeItem(at: blocked)
        await model.retrySave()
        XCTAssertEqual(model.saveState, .saved)
        XCTAssertEqual(try store.load("draft.json", as: ReviewInput.self), input)
    }
    func testNativeFileImportAndInvalidFilePreserveEditableDraft() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(api: API(), store: try DeviceStore(root: root))
        await model.waitUntilLoaded()
        let file = root.appendingPathComponent("订单.md")
        let content = "# 订单设计\n\n超时后先查询状态，再决定重试。"
        try Data(content.utf8).write(to: file)
        await model.importDocument(file)
        await model.retrySave()
        XCTAssertEqual(model.draft.title, "订单")
        XCTAssertEqual(model.draft.design, content)
        try Data([0xC3, 0x28]).write(to: file)
        await model.importDocument(file)
        XCTAssertEqual(model.draft.design, content)
    }
    func testFailedAnswerSaveKeepsInputAndPreventsSubmission() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let id = "answer-review"
        let review = ReviewSnapshot(id: id, revision: 2, status: "waiting_input", input: ReviewInput(),
            sources: [:], questions: [Question(id: "q1", text: "如何处理超时？")], answers: [:], report: nil, error: nil)
        try store.saveReview(review)
        let api = API()
        let model = WorkspaceModel(api: api, store: store)
        await model.waitUntilLoaded()
        model.showSaved(true)
        await model.refresh()
        await model.open(id)
        let file = root.appendingPathComponent("answers-" + Data(id.utf8).map { String(format: "%02x", $0) }.joined() + ".json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        model.editAnswer("q1", "最新回答：先查询状态，再决定重试。")
        await model.answer()
        XCTAssertEqual(model.answers["q1"], "最新回答：先查询状态，再决定重试。")
        XCTAssertEqual(model.saveState, .failed)
        XCTAssertEqual(api.writes, 0)
        try FileManager.default.removeItem(at: file)
        await model.retrySave()
        XCTAssertEqual(try store.answers(id)["q1"], "最新回答：先查询状态，再决定重试。")
    }
    func testLegacyCacheMigratesAndMultipleReportsRemainOfflineAfterReload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        try store.save("review.json", value: snapshot("legacy"))
        try store.saveReview(snapshot("second"))
        let reloaded = try DeviceStore(root: root)
        XCTAssertEqual(Set(try reloaded.savedReviews().map(\.id)), ["legacy", "second"])
        let api = API()
        let model = WorkspaceModel(api: api, store: reloaded)
        await model.waitUntilLoaded()
        model.showSaved(true)
        await model.refresh()
        for id in ["legacy", "second"] {
            await model.open(id)
            XCTAssertEqual(model.review?.id, id)
            await model.export()
            XCTAssertTrue(model.exported.contains("报告结论 " + id))
            XCTAssertTrue(model.exported.contains("> 先查询状态") && model.exported.contains("SHA-256 digest"))
        }
        XCTAssertEqual(api.calls, 0, "Saved reports, citations and sharing must not require the server")
    }
    func testReportCacheKeepsMostRecentTwenty() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        for number in 0..<23 { try store.saveReview(snapshot(String(number))) }
        let saved = try DeviceStore(root: root).savedReviews().map(\.id)
        XCTAssertEqual(saved.count, 20)
        XCTAssertEqual(saved.first, "22")
        XCTAssertFalse(saved.contains("0"))
    }
    func testQueuedEditsKeepLatestAfterRapidTypingAndFlush() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        let model = WorkspaceModel(api: API(), store: store)
        await model.waitUntilLoaded()
        for number in 0..<100 {
            var input = ReviewInput()
            input.title = "版本 \(number)"; input.design = "订单超时后先查询状态，再决定重试。"
            model.edit(input)
        }
        await model.retrySave()
        XCTAssertEqual(model.draft.title, "版本 99")
        XCTAssertEqual(try store.load("draft.json", as: ReviewInput.self)?.title, "版本 99")
    }
}
