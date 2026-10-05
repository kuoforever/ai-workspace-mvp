import SwiftUI
import UniformTypeIdentifiers

@MainActor struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionHelp = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.busy || model.loadingLocal { ProgressView().accessibilityIdentifier("busy").padding(6) }
                content.frame(maxWidth: 840)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("AI Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .alert("连接电脑工作台", isPresented: $connectionHelp) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text("在运行此模拟器的 Mac 上启动 AI Workspace 后端，再检查连接并刷新。\n\n当前地址：http://localhost:8765\n连接成功表示后端可用；评审仍需电脑上的 MCP 助手处理。")
            }
            .toolbar {
                if model.page != .home {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回", systemImage: "chevron.left") { Task { await model.back() } }
                            .disabled(model.busy).accessibilityIdentifier("back")
                    }
                }
                if model.page == .home || model.page == .detail {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                            .disabled(model.busy).accessibilityIdentifier("refresh")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }.accessibilityIdentifier("keyboard-dismiss")
                }
            }
            .task { await model.refresh() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    if model.shouldPoll { await model.refresh(autoRefresh: true) }
                }
            }
        }
    }
    private var status: WorkspaceStatusView {
        WorkspaceStatusView(model: model) { connectionHelp = true }
    }
    @ViewBuilder private var content: some View {
        switch model.page {
        case .home: HomeView(model: model, status: status)
        case .create: CreateReviewView(model: model, status: status)
        case .detail: ReviewDetailView(model: model, status: status)
        case .source: SourceView(source: model.source, quote: model.quote, status: status)
        case .export:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    status
                    Text("导出预览").font(.title2.bold()).accessibilityIdentifier("export-title")
                    ShareLink(item: model.exported) { Label("分享报告", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent).tint(.workspaceButton).accessibilityIdentifier("share-report")
                    Text(verbatim: model.exported).font(.footnote).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }
}

@MainActor private struct WorkspaceStatusView: View {
    @ObservedObject var model: WorkspaceModel
    let help: () -> Void
    private var connectionLabel: some View {
        Text(model.connection.rawValue).font(.caption).accessibilityIdentifier("connection-status")
    }
    private var actions: some View {
        HStack(spacing: 12) {
            Button { Task { await model.checkConnection() } } label: {
                Text("检查连接").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
            }.disabled(model.busy || model.startupError != nil).accessibilityIdentifier("check-connection")
            Button(action: help) { Text("帮助").fixedSize(horizontal: false, vertical: true).frame(minHeight: 44) }
        }.font(.footnote)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    connectionLabel.fixedSize()
                    Spacer(minLength: 12)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    connectionLabel.fixedSize(horizontal: false, vertical: true)
                    actions
                }
            }
            if let message = model.startupError ?? model.error { notice(message, color: .red) }
            if model.startupError != nil {
                Button("重新读取本机记录") { Task { await model.reloadLocalData() } }
                    .disabled(model.busy || model.loadingLocal).accessibilityIdentifier("reload-local")
            }
            Text(model.saveState.rawValue).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("save-state")
            if model.saveState == .failed {
                Button("重试保存") { Task { await model.retrySave() } }
                    .disabled(model.busy).accessibilityIdentifier("retry-save")
            }
            if model.pending != nil {
                notice("上次提交结果尚未确认。重试沿用原请求，输入暂时锁定。", color: .workspaceTeal)
                Button("重试原提交") { Task { await model.retry() } }
                    .buttonStyle(.bordered).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.08))
    }
}

@MainActor private struct HomeView: View {
    @ObservedObject var model: WorkspaceModel
    let status: WorkspaceStatusView
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                status
                Link(destination: URL(string: "http://localhost:8765/workspace")!) {
                    Label("通用工作台 · 在浏览器中打开", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.bordered).disabled(model.busy).accessibilityIdentifier("general-workbench")
                Text("把设计，变成有依据的判断。").font(.title2.bold())
                Text(model.savedOnly ? "设备中的评审快照" : (model.cached ? "显示本机缓存 · 联网后刷新" : "与电脑工作台共享评审记录"))
                    .font(.footnote).foregroundStyle(.secondary)
                Button { model.createPage() } label: {
                    Label("新建设计评审", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).tint(.workspaceButton).disabled(!model.editable).accessibilityIdentifier("new-review")
                if (model.savedOnly ? model.savedRows : model.rows).isEmpty {
                    ContentUnavailableView(model.savedOnly ? "还没有保存的评审" : "还没有评审", systemImage: "doc.text.magnifyingglass",
                        description: Text(model.savedOnly ? "打开记录后，会自动保存到设备。" : "创建一份设计，或在电脑提交后刷新。"))
                }
                HStack {
                    Button("全部评审") { model.showSaved(false) }.disabled(model.busy || model.loadingLocal)
                        .tint(model.savedOnly ? .secondary : .workspaceTeal)
                    Button("已保存 · \(model.savedRows.count)") { model.showSaved(true) }
                        .disabled(model.busy || model.loadingLocal).accessibilityIdentifier("saved-library")
                        .tint(model.savedOnly ? .workspaceTeal : .secondary)
                }.buttonStyle(.bordered)
                Text("已打开的最近 20 份评审保存在设备，可离线阅读引用和分享报告。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(model.savedOnly ? model.savedRows : model.rows) { row in
                    Button { Task { await model.open(row.id) } } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(row.title).font(.headline).foregroundStyle(.primary)
                            Text("\(statusLabel(row.status)) · \(row.mode == "scripted" ? "离线模拟" : "助手评审")")
                                .font(.subheadline).foregroundStyle(Color.workspaceTeal)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("review:\(row.id)")
                }
                Text("人工检查由你确认，AI 报告单独保存。").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}

@MainActor private struct CreateReviewView: View {
    @ObservedObject var model: WorkspaceModel
    let status: WorkspaceStatusView
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var choosing = false
    @State private var importing = false
    @State private var replaceImport = false
    @State private var query = ""
    private enum Field { case title, design }
    @FocusState private var focusedField: Field?
    private func binding<T>(_ key: WritableKeyPath<ReviewInput, T>) -> Binding<T> {
        Binding(get: { model.draft[keyPath: key] }, set: { value in
            var next = model.draft; next[keyPath: key] = value; model.edit(next)
        })
    }
    var body: some View {
        Form {
            Section { status }
            Section("描述你的设计") {
                Button("导入 Markdown / 文本", systemImage: "doc.badge.plus") {
                    focusedField = nil
                    if model.draft.design.isEmpty { importing = true } else { replaceImport = true }
                }.accessibilityIdentifier("import-document")
                Text("支持 UTF-8 的 .md、.markdown、.txt，10–8000 字符。").font(.caption).foregroundStyle(.secondary)
                Button("填入演示示例") { model.example() }
                TextField("评审名称", text: binding(\.title)).focused($focusedField, equals: .title)
                    .accessibilityIdentifier("review-title")
                TextEditor(text: binding(\.design)).focused($focusedField, equals: .design)
                    .frame(minHeight: 150).accessibilityIdentifier("design")
                Text("\(model.draft.design.unicodeScalars.count)/8000 字符 · \(model.saveState.rawValue)").font(.caption).foregroundStyle(.secondary)
            }.disabled(!model.editable)
            Section("检查范围 · \(model.draft.checkIDs.count)/8") {
                Text(model.draft.checkIDs.joined(separator: " · ")).font(.subheadline)
                Button("调整检查项") { focusedField = nil; choosing = true }.disabled(model.checks.isEmpty)
            }.disabled(!model.editable)
            Section {
                if textSize.isAccessibilitySize {
                    modeOption("助手评审", value: "mcp")
                    modeOption("离线模拟", value: "scripted")
                } else {
                    modePicker.pickerStyle(.segmented)
                }
                Text(model.draft.mode == "mcp" ? "提交后，让电脑中连接 MCP 的助手处理。手机可继续回答和查看结果。" : "固定程序展示流程，本次不调用模型。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.disabled(!model.editable)
        }
        .accessibilityIdentifier("create-form")
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.draft.mode) { _, _ in focusedField = nil }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("提交评审", systemImage: "checkmark") { Task { await model.create() } }
                    .disabled(!model.editable).accessibilityIdentifier("submit")
            }
        }
        .confirmationDialog("替换设计材料？", isPresented: $replaceImport, titleVisibility: .visible) {
            Button("选择文件") { importing = true }
        } message: { Text("所选文件会替换当前设计材料。取消或导入失败会保留原草稿。") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [
            .plainText, UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]) { result in
            switch result {
            case .success(let url): Task { await model.importDocument(url) }
            case .failure(let failure): model.importFailed(failure)
            }
        }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                List(model.checks.filter { query.isEmpty || ($0.id + $0.question).localizedCaseInsensitiveContains(query) }) { check in
                    Button { model.toggle(check.id) } label: {
                        HStack(alignment: .top) {
                            Image(systemName: model.draft.checkIDs.contains(check.id) ? "checkmark.circle.fill" : "circle")
                            Text("\(check.id) \(check.question)").foregroundStyle(.primary)
                        }
                    }.disabled(!model.editable || (model.draft.checkIDs.count >= 8 && !model.draft.checkIDs.contains(check.id)))
                }
                .searchable(text: $query, prompt: "编号或关键词")
                .navigationTitle("选择检查 · \(model.draft.checkIDs.count)/8")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { choosing = false } } }
            }
        }
    }
    private var modePicker: some View {
        Picker("评审方式", selection: binding(\.mode)) {
            Text("助手评审").tag("mcp")
            Text("离线模拟").tag("scripted")
        }
    }
    private func modeOption(_ title: String, value: String) -> some View {
        Button {
            var next = model.draft
            next.mode = value
            model.edit(next)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.draft.mode == value ? "checkmark.circle.fill" : "circle")
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityValue(model.draft.mode == value ? "已选择" : "未选择")
    }
}

@MainActor private struct ReviewDetailView: View {
    @ObservedObject var model: WorkspaceModel
    let status: WorkspaceStatusView
    @State private var copied = false
    var body: some View {
        ScrollView {
            if let review = model.review {
                VStack(alignment: .leading, spacing: 20) {
                    status
                    Text(statusLabel(review.status)).font(.subheadline.bold()).foregroundStyle(Color.workspaceTeal)
                        .accessibilityIdentifier("review-status")
                    Text(review.input.title).font(.title2.bold())
                    Text("\(review.input.checkIDs.count) 项检查 · 版本 \(review.revision)").font(.footnote).foregroundStyle(.secondary)
                    if model.cached { Text("缓存快照 · 刷新以核对最新状态").font(.footnote).foregroundStyle(.orange) }
                    if review.input.mode == "scripted" { Text("离线模拟 · 未经模型评审").foregroundStyle(.secondary) }
                    if review.status == "waiting_model" {
                        Text(model.cached ? "这是上次保存的等待状态，请先恢复连接并刷新。" : "材料已保存，等待电脑助手接手。将下面的指令发送给已连接 MCP 的助手；结果返回后，此页面会自动更新。")
                        Button(copied ? "指令已复制" : "复制助手指令", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = assistantPrompt(review.id)
                            copied = true
                        }.accessibilityIdentifier("copy-assistant-prompt")
                    }
                    if review.status == "running" {
                        Text("工作台正在保存或处理本次操作，完成后页面会自动更新。")
                    }
                    if let error = review.error { Text(error).foregroundStyle(.red) }
                    if review.status == "waiting_input" {
                        ForEach(review.questions) { question in
                            VStack(alignment: .leading) {
                                Text(question.text).font(.headline)
                                TextEditor(text: Binding(get: { model.answers[question.id] ?? "" },
                                    set: { model.editAnswer(question.id, $0) }))
                                    .frame(minHeight: 110).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 12))
                                    .disabled(!model.canEditAnswers).accessibilityIdentifier("answer:\(question.id)")
                            }
                        }
                        Button("保存回答并继续") { Task { await model.answer() } }
                            .buttonStyle(.borderedProminent).tint(.workspaceButton).disabled(!model.editable).accessibilityIdentifier("answer-submit")
                    }
                    if let report = review.report {
                        Text(report.summary).accessibilityIdentifier("report-summary")
                        ForEach(report.findings) { finding in
                            VStack(alignment: .leading, spacing: 14) {
                                Text("\(finding.checkID) · \(verdictLabel(finding.verdict))").font(.headline)
                                Text(finding.explanation)
                                Text("下一步").font(.headline).foregroundStyle(Color.workspaceTeal)
                                Text(finding.recommendation)
                                ForEach(Array(finding.citations.enumerated()), id: \.offset) { index, citation in
                                    Button("查看依据 · \(citation.sourceID)") { model.openSource(citation) }
                                        .disabled(model.busy).accessibilityIdentifier("source:\(finding.checkID):\(index)")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                        }
                        Text("引用已通过程序校验，语义仍需人工判断。代码与实验未执行。").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("导出 Markdown", systemImage: "square.and.arrow.up") { Task { await model.export() } }
                        .buttonStyle(.bordered).disabled(model.busy).accessibilityIdentifier("export")
                    Text("设计快照").font(.headline)
                    Text(review.input.design).font(.footnote).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }.accessibilityIdentifier("detail-scroll").scrollDismissesKeyboard(.interactively)
    }
}

@MainActor private struct SourceView: View {
    let source: Source?
    let quote: String
    let status: WorkspaceStatusView
    var body: some View {
        ScrollView {
            if let source {
                VStack(alignment: .leading, spacing: 20) {
                    status
                    Text("引用依据").font(.title2.bold()).accessibilityIdentifier("source-title")
                    Text(source.title).font(.headline)
                    if let excerpt = sourceExcerpt(source.text, quote: quote) {
                        Text("原文第 \(excerpt.firstLine)–\(excerpt.lastLine) 行")
                            .font(.footnote).accessibilityIdentifier("source-location")
                        (Text(excerpt.before) + Text(excerpt.quote).foregroundColor(.workspaceTeal).bold().underline() + Text(excerpt.after))
                            .textSelection(.enabled).padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.workspaceTeal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("source-context")
                    } else {
                        Text("未在此快照找到对应片段，请核对来源。").foregroundStyle(.red)
                        Text(quote).textSelection(.enabled)
                    }
                    Text(source.path).font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("来源校验信息") { Text("SHA-256 \(source.sha256)").font(.caption).textSelection(.enabled) }
                    DisclosureGroup("查看完整来源") {
                        Text(source.text).font(.subheadline).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }
}
