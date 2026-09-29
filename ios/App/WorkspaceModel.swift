import Foundation
import Combine

enum Page: Equatable { case home, create, detail, source, export }

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var page: Page = .home
    @Published private(set) var rows: [ReviewSummary] = []
    @Published private(set) var checks: [CheckCard] = []
    @Published private(set) var draft = ReviewInput()
    @Published private(set) var review: ReviewSnapshot?
    @Published private(set) var answers: [String: String] = [:]
    @Published private(set) var pending: PendingCommand?
    @Published private(set) var busy = false
    @Published private(set) var cached = true
    @Published private(set) var error: String?
    @Published private(set) var startupError: String?
    @Published private(set) var source: Source?
    @Published private(set) var quote = ""
    @Published private(set) var exported = ""
    private let api: WorkspaceAPI
    private var store: DeviceStore?
    private var journal: CommandJournal?
    private var selectedID: String?

    init(api: WorkspaceAPI? = nil) {
        self.api = api ?? LocalWorkspaceAPI()
        do {
            let store = try DeviceStore()
            self.store = store
            journal = try CommandJournal(store: store, api: self.api)
            pending = journal?.pending
            draft = try store.load("draft.json", as: ReviewInput.self) ?? ReviewInput()
            rows = try store.load("list.json", as: [ReviewSummary].self) ?? []
            review = try store.load("review.json", as: ReviewSnapshot.self)
        } catch {
            startupError = "本机记录无法读取，写入已暂停。请保留应用数据后排查，避免重复提交。"
        }
    }
    var editable: Bool { !busy && pending == nil && startupError == nil }
    var shouldPoll: Bool {
        page == .detail && !busy && error == nil && ["waiting_model", "running"].contains(review?.status ?? "")
    }
    private func operation(_ work: () async throws -> Void) async {
        guard !busy, startupError == nil else { return }
        busy = true
        error = nil
        defer { busy = false; pending = journal?.pending }
        do { try await work() }
        catch is CancellationError { }
        catch let failure as APIError {
            error = failure.message + (failure.status == 409 ? "。输入已保留，请刷新核对后再提交。" : "")
        } catch let failure as URLError {
            if failure.code != .cancelled {
                cached = true
                error = "未能连接工作台。请启动同一台 Mac 上的服务；输入仍保存在本机。"
            }
        } catch { self.error = "操作未完成，原提交与输入均按已有状态保留：\(error.localizedDescription)" }
    }
    func refresh() async {
        await operation {
            if self.checks.isEmpty {
                self.checks = try Wire.decode(Catalog.self, await self.api.get("/catalog")).checks
            }
            if self.page == .detail, let id = self.selectedID {
                try self.show(Wire.decode(ReviewSnapshot.self, await self.api.get("/reviews/\(id)")))
            } else {
                let rows = try Wire.decode([ReviewSummary].self, await self.api.get("/reviews"))
                try self.store?.save("list.json", value: rows)
                self.rows = rows
                self.cached = false
            }
        }
    }
    func open(_ id: String) async {
        await operation {
            self.selectedID = id
            if self.review?.id != id { self.review = nil }
            self.page = .detail
            self.answers = try self.store?.answers(id) ?? [:]
            self.cached = true
            try self.show(Wire.decode(ReviewSnapshot.self, await self.api.get("/reviews/\(id)")))
        }
    }
    private func show(_ value: ReviewSnapshot) throws {
        try store?.save("review.json", value: value)
        answers = try store?.answers(value.id) ?? [:]
        review = value
        selectedID = value.id
        cached = false
        page = .detail
    }
    func createPage() { guard editable else { return }; error = nil; page = .create }
    func back() async {
        guard !busy else { return }
        if page == .source || page == .export { page = .detail }
        else { page = .home; await refresh() }
    }
    func edit(_ value: ReviewInput) {
        guard editable else { return }
        do { try store?.save("draft.json", value: value); draft = value }
        catch { self.error = "草稿未能保存：\(error.localizedDescription)" }
    }
    func example() {
        var value = ReviewInput()
        value.title = "订单接口设计"
        value.design = "订单使用请求键去重；支付超时后直接重试，尚未设计结果查询。"
        value.mode = "scripted"
        edit(value)
    }
    func toggle(_ id: String) {
        var next = draft
        if next.checkIDs.contains(id) { next.checkIDs.removeAll { $0 == id } }
        else if next.checkIDs.count < 8 { next.checkIDs.append(id) }
        edit(next)
    }
    func create() async {
        var value = draft
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(value.title.unicodeScalars.count),
              (10...8000).contains(value.design.unicodeScalars.count), (1...8).contains(value.checkIDs.count) else {
            error = "请填写名称、10–8000 字符的设计，并选择 1–8 项检查。"; return
        }
        await operation {
            try await self.send(PendingCommand(key: UUID().uuidString, path: "/reviews",
                body: Wire.encode(value), kind: "create"))
        }
    }
    func editAnswer(_ id: String, _ value: String) {
        guard editable, let reviewID = review?.id else { return }
        var next = answers
        next[id] = value
        do { try store?.saveAnswers(reviewID, next); answers = next }
        catch { self.error = "回答未能保存：\(error.localizedDescription)" }
    }
    func answer() async {
        guard let review else { return }
        let values = Dictionary(uniqueKeysWithValues: review.questions.map { ($0.id, answers[$0.id] ?? "") })
        guard !values.isEmpty, values.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.unicodeScalars.count <= 2000 }) else {
            error = "请回答每个问题，最多 2000 字符；不确定时可填写‘暂不确定’。"; return
        }
        await operation {
            try await self.send(PendingCommand(key: UUID().uuidString, path: "/reviews/\(review.id)/answers",
                body: Wire.encode(AnswerCommand(revision: review.revision, answers: values)), kind: "answer", reviewID: review.id))
        }
    }
    func retry() async { await operation { try await self.send(nil) } }
    private func send(_ candidate: PendingCommand?) async throws {
        guard let journal, let action = journal.pending ?? candidate else { return }
        let result = try await journal.send(candidate)
        if action.kind == "create" {
            try store?.save("draft.json", value: ReviewInput())
            draft = ReviewInput()
        } else if let id = action.reviewID { try store?.saveAnswers(id, [:]) }
        try show(result)
    }
    func openSource(_ citation: Citation) {
        guard !busy, let value = review?.sources[citation.sourceID] else { return }
        source = value; quote = citation.quote; page = .source
    }
    func export() async {
        guard let id = review?.id else { return }
        await operation {
            let data = try await self.api.get("/reviews/\(id)/export?format=markdown")
            guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            self.exported = text; self.page = .export
        }
    }
}
