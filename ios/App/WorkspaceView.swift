import SwiftUI

@MainActor struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var connectionHelp = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.busy { ProgressView().accessibilityIdentifier("busy").padding(6) }
                HStack {
                    Text(model.connection.rawValue).font(.caption).accessibilityIdentifier("connection-status")
                    Spacer()
                    Button("检查连接") { Task { await model.checkConnection() } }
                        .disabled(model.busy || model.startupError != nil).accessibilityIdentifier("check-connection")
                    Button("帮助") { connectionHelp = true }
                }.font(.footnote).padding(.horizontal, 20).padding(.vertical, 8)
                if let message = model.startupError ?? model.error { notice(message, color: .red) }
                if model.pending != nil {
                    notice("上次提交结果尚未确认。重试沿用原请求，输入暂时锁定。", color: .workspaceTeal)
                    Button("重试原提交") { Task { await model.retry() } }
                        .buttonStyle(.bordered).disabled(model.busy).padding(.bottom, 8)
                }
                content
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
                    if model.shouldPoll { await model.refresh() }
                }
            }
        }
    }
    @ViewBuilder private var content: some View {
        switch model.page {
        case .home: HomeView(model: model)
        case .create: CreateReviewView(model: model)
        case .detail: ReviewDetailView(model: model)
        case .source: SourceView(source: model.source, quote: model.quote)
        case .export:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("导出预览").font(.title2.bold()).accessibilityIdentifier("export-title")
                    ShareLink(item: model.exported) { Label("分享报告", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("share-report")
                    Text(verbatim: model.exported).font(.footnote).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }
    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.08)).padding(.horizontal, 16).padding(.vertical, 4)
    }
}

@MainActor private struct HomeView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("把设计，变成有依据的判断。").font(.title2.bold())
                Text(model.cached ? "显示本机缓存 · 联网后刷新" : "与电脑工作台共享评审记录")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { model.createPage() } label: {
                    Label("新建设计评审", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).disabled(!model.editable).accessibilityIdentifier("new-review")
                if model.rows.isEmpty {
                    ContentUnavailableView("还没有评审", systemImage: "doc.text.magnifyingglass",
                        description: Text("创建一份设计，或在电脑提交后刷新。"))
                }
                ForEach(model.rows) { row in
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
    @State private var choosing = false
    @State private var query = ""
    private func binding<T>(_ key: WritableKeyPath<ReviewInput, T>) -> Binding<T> {
        Binding(get: { model.draft[keyPath: key] }, set: { value in
            var next = model.draft; next[keyPath: key] = value; model.edit(next)
        })
    }
    var body: some View {
        Form {
            Section("描述你的设计") {
                Button("填入演示示例") { model.example() }
                TextField("评审名称", text: binding(\.title)).accessibilityIdentifier("review-title")
                TextEditor(text: binding(\.design)).frame(minHeight: 150).accessibilityIdentifier("design")
                Text("\(model.draft.design.unicodeScalars.count)/8000 字符 · 草稿保存在设备").font(.caption).foregroundStyle(.secondary)
            }
            Section("检查范围 · \(model.draft.checkIDs.count)/8") {
                Text(model.draft.checkIDs.joined(separator: " · ")).font(.subheadline)
                Button("调整检查项") { choosing = true }.disabled(model.checks.isEmpty)
            }
            Section {
                Picker("评审方式", selection: binding(\.mode)) {
                    Text("助手评审").tag("mcp")
                    Text("离线模拟").tag("scripted")
                }.pickerStyle(.segmented)
                Text(model.draft.mode == "mcp" ? "提交后，让电脑中连接 MCP 的助手处理。手机可继续回答和查看结果。" : "固定程序展示流程，本次不调用模型。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { Task { await model.create() } } label: {
                    Text("提交评审").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("submit")
            }
        }
        .disabled(!model.editable)
        .scrollDismissesKeyboard(.interactively)
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
}

@MainActor private struct ReviewDetailView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var copied = false
    var body: some View {
        ScrollView {
            if let review = model.review {
                VStack(alignment: .leading, spacing: 20) {
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
                                    .disabled(!model.editable).accessibilityIdentifier("answer:\(question.id)")
                            }
                        }
                        Button("保存回答并继续") { Task { await model.answer() } }
                            .buttonStyle(.borderedProminent).disabled(!model.editable).accessibilityIdentifier("answer-submit")
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
    var body: some View {
        ScrollView {
            if let source {
                VStack(alignment: .leading, spacing: 20) {
                    Text("引用依据").font(.title2.bold()).accessibilityIdentifier("source-title")
                    Text(source.title).font(.headline)
                    Text(quote).textSelection(.enabled).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.workspaceTeal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    Text(source.path).font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("来源校验信息") { Text("SHA-256 \(source.sha256)").font(.caption).textSelection(.enabled) }
                    Text("评审时保存的来源快照").font(.headline)
                    Text(source.text).font(.subheadline).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
    }
}
