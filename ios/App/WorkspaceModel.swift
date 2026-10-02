import Foundation
import Combine

enum Page: Equatable { case home, create, detail, source, export }

@MainActor final class WorkspaceModel: ObservableObject {
    @Published var page: Page = .home
    @Published private(set) var rows: [ReviewSummary] = []
    @Published private(set) var checks: [CheckCard] = []
    @Published private(set) var savedRows: [ReviewSummary] = []
    @Published private(set) var savedOnly = false
    @Published private(set) var draft = ReviewInput()
    @Published private(set) var review: ReviewSnapshot?
    @Published private(set) var answers: [String: String] = [:]
    @Published private(set) var pending: PendingCommand?
    @Published private(set) var busy = false
    @Published private(set) var loadingLocal = true
    @Published private(set) var saveState: SaveState = .saved
    @Published private(set) var cached = true
    @Published private(set) var error: String?
    @Published private(set) var startupError: String?
    @Published private(set) var connection: ConnectionState = .unknown
    @Published private(set) var source: Source?
    @Published private(set) var quote = ""
    @Published private(set) var exported = ""
    private let api: WorkspaceAPI
    private let disk = DiskExecutor()
    private lazy var observedAPI = ObservedWorkspaceAPI(base: api) { [weak self] state in self?.connection = state }
    private lazy var edits = EditPersistence { [weak self] state in self?.saveState = state }
    private var store: DeviceStore?
    private var journal: CommandJournal?
    private var selectedID: String?
    private var loadingTask: Task<Void, Never>?

    init(api: WorkspaceAPI? = nil, store suppliedStore: DeviceStore? = nil) {
        self.api = api ?? LocalWorkspaceAPI()
        loadingTask = Task { [weak self] in
            if let self { await self.loadLocal(suppliedStore) }
        }
    }
    func waitUntilLoaded() async { await loadingTask?.value }
    private func loadLocal(_ supplied: DeviceStore?) async {
        defer { loadingLocal = false }
        do {
            let device = try await disk.run { try supplied ?? DeviceStore() }
            store = device
            journal = try await CommandJournal(store: device, api: observedAPI, disk: disk)
            pending = journal?.pending
            let local = try await disk.run {
                (try device.load("draft.json", as: ReviewInput.self) ?? ReviewInput(),
                 try device.load("list.json", as: [ReviewSummary].self) ?? [],
                 try device.cachedReview(), try device.savedReviews().map(\.summary))
            }
            draft = local.0; rows = local.1; review = local.2; savedRows = local.3
        } catch {
            startupError = "本机记录无法读取，写入已暂停。请保留应用数据后排查，避免重复提交。"
        }
    }
    var editable: Bool { !busy && !loadingLocal && pending == nil && startupError == nil }
    var shouldPoll: Bool {
        !cached && !savedOnly && page == .detail && !busy && error == nil &&
            ["waiting_model", "running"].contains(review?.status ?? "")
    }
    private func operation(_ work: () async throws -> Void) async {
        await waitUntilLoaded()
        guard !busy, startupError == nil else { return }
        busy = true; error = nil
        defer { busy = false; pending = journal?.pending }
        do { try await work() }
        catch is CancellationError { }
        catch let failure as APIError {
            error = failure.message + (failure.status == 409 ? "。输入已保留，请刷新核对后再提交。" : "")
        } catch let failure as URLError {
            if failure.code != .cancelled {
                cached = true
                error = "未能连接工作台。请启动同一台 Mac 上的服务；输入仍保留在设备。"
            }
        } catch { self.error = "操作未完成，输入与原提交已保留：\(error.localizedDescription)" }
    }
    func refresh() async {
        await operation {
            guard let store = self.store else { return }
            if self.page == .home && self.savedOnly {
                let local = try await self.disk.run { try store.savedReviews().map(\.summary) }
                self.savedRows = local
                return
            }
            if self.checks.isEmpty {
                self.checks = try Wire.decode(Catalog.self, await self.observedAPI.get("/catalog")).checks
            }
            if self.page == .detail, let id = self.selectedID {
                try await self.show(Wire.decode(ReviewSnapshot.self, await self.observedAPI.get("/reviews/\(id)")))
            } else {
                let rows = try Wire.decode([ReviewSummary].self, await self.observedAPI.get("/reviews"))
                try await self.disk.run { try store.save("list.json", value: rows) }
                self.rows = rows; self.cached = false
            }
        }
    }
    func showSaved(_ value: Bool) {
        guard !busy, !loadingLocal else { return }
        savedOnly = value; error = nil
        if value { Task { await refresh() } }
    }
    func checkConnection() async {
        await operation {
            self.connection = .checking
            let data = try await self.observedAPI.get("/config")
            do {
                let config = try Wire.decode(ServerConfig.self, data)
                guard config.modes.contains("mcp") else { throw URLError(.badServerResponse) }
            } catch {
                self.connection = .unavailable
                throw APIError(status: 0, message: "连接到的服务未返回有效工作台配置，请核对电脑上的服务。")
            }
        }
    }
    func open(_ id: String) async {
        await operation {
            guard let store = self.store else { return }
            let local = try await self.disk.run { (try store.cachedReview(id), try store.answers(id)) }
            self.selectedID = id; self.review = local.0; self.answers = local.1
            self.page = .detail; self.cached = true
            if !self.savedOnly || self.review == nil {
                try await self.show(Wire.decode(ReviewSnapshot.self, await self.observedAPI.get("/reviews/\(id)")))
            }
        }
    }
    private func show(_ value: ReviewSnapshot) async throws {
        guard let store else { return }
        let local = try await disk.run {
            try store.saveReview(value)
            return (try store.answers(value.id), try store.savedReviews().map(\.summary))
        }
        answers = local.0; savedRows = local.1; review = value; selectedID = value.id
        cached = false; page = .detail
    }
    func createPage() { guard editable else { return }; error = nil; page = .create }
    func back() async {
        guard !busy else { return }
        if page == .source || page == .export { page = .detail }
        else { page = .home; await refresh() }
    }
    func edit(_ value: ReviewInput) {
        guard editable, let store else { return }
        draft = value
        let disk = self.disk
        edits.enqueue("draft") { try await disk.run { try store.save("draft.json", value: value) } }
    }
    func importDocument(_ url: URL) async {
        guard editable else { return }
        await operation {
            let imported = try await self.disk.run { try DocumentImport.read(url) }
            guard let store = self.store else { return }
            var value = self.draft
            value.design = imported.text
            if value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.title = String(String.UnicodeScalarView((imported.name as NSString).deletingPathExtension.unicodeScalars.prefix(120)))
            }
            self.draft = value
            let snapshot = value, disk = self.disk
            self.edits.enqueue("draft") { try await disk.run { try store.save("draft.json", value: snapshot) } }
        }
    }
    func importFailed(_ failure: Error) {
        if (failure as NSError).code != NSUserCancelledError { error = "未能导入文件，原草稿已保留：\(failure.localizedDescription)" }
    }
    func example() {
        var value = ReviewInput()
        value.title = "订单接口设计"; value.design = "订单使用请求键去重；支付超时后直接重试，尚未设计结果查询。"
        value.mode = "scripted"; edit(value)
    }
    func toggle(_ id: String) {
        var next = draft
        if next.checkIDs.contains(id) { next.checkIDs.removeAll { $0 == id } }
        else if next.checkIDs.count < 8 { next.checkIDs.append(id) }
        edit(next)
    }
    func retrySave() async { await operation { try await self.edits.flush() } }
    func create() async {
        guard editable else { return }
        var value = draft
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(value.title.unicodeScalars.count),
              (10...8000).contains(value.design.unicodeScalars.count), (1...8).contains(value.checkIDs.count) else {
            error = "请填写名称、10–8000 字符的设计，并选择 1–8 项检查。"; return
        }
        let input = value
        await operation {
            try await self.send(PendingCommand(key: UUID().uuidString, path: "/reviews",
                body: Wire.encode(input), kind: "create"))
        }
    }
    func editAnswer(_ id: String, _ value: String) {
        guard editable, let reviewID = review?.id, let store else { return }
        var next = answers; next[id] = value
        answers = next
        let snapshot = next, disk = self.disk
        edits.enqueue("answers:" + reviewID) { try await disk.run { try store.saveAnswers(reviewID, snapshot) } }
    }
    func answer() async {
        guard editable, let review else { return }
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
        try await edits.flush()
        guard let journal, let action = journal.pending ?? candidate, let store else { return }
        _ = try await journal.send(candidate) { result in
            try await self.disk.run {
                try store.saveReview(result)
                if action.kind == "create" { try store.save("draft.json", value: ReviewInput()) }
                else if let id = action.reviewID { try store.saveAnswers(id, [:]) }
            }
            if action.kind == "create" { self.draft = ReviewInput() }
            try await self.show(result)
        }
    }
    func openSource(_ citation: Citation) {
        guard !busy, let value = review?.sources[citation.sourceID] else { return }
        source = value; quote = citation.quote; page = .source
    }
    func export() async {
        guard let review else { return }
        await operation {
            self.exported = try await self.disk.run { review.markdown }
            self.page = .export
        }
    }
}
