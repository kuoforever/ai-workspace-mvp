package io.github.kuoforever.aiworkspace

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.io.IOException
import java.net.URLEncoder
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString

enum class Page { HOME, CREATE, DETAIL, SOURCE, EXPORT }

data class WorkspaceUi(
    val page: Page = Page.HOME,
    val rows: List<ReviewSummary> = emptyList(),
    val savedRows: List<ReviewSummary> = emptyList(),
    val savedOnly: Boolean = false,
    val checks: List<CheckCard> = emptyList(),
    val draft: ReviewInput = ReviewInput(),
    val review: ReviewSnapshot? = null,
    val selectedId: String? = null,
    val answers: Map<String, String> = emptyMap(),
    val source: Source? = null,
    val quote: String = "",
    val exported: String = "",
    val busy: Boolean = false,
    val refreshing: Boolean = false,
    val loadingLocal: Boolean = true,
    val saveState: SaveState = SaveState.SAVED,
    val cached: Boolean = true,
    val error: String? = null,
    val pending: PendingCommand? = null,
    val startupError: String? = null,
    val connection: Connection = Connection.UNKNOWN,
) {
    val editable: Boolean get() = !busy && !loadingLocal && pending == null && startupError == null
    val canEditAnswers: Boolean get() = (!busy || refreshing) && !loadingLocal && pending == null && startupError == null
    val shouldPoll: Boolean get() = page == Page.DETAIL && !cached && !busy && error == null &&
        review?.status in listOf("waiting_model", "waiting_input", "running")
}

class WorkspaceViewModel(
    private val api: WorkspaceApi,
    private val store: WorkspaceStore,
    private val disk: DiskExecutor = DiskExecutor(),
) : ViewModel() {
    private var journal: CommandJournal? = null
    private var polling: Job? = null
    private val edits = EditPersistence(viewModelScope, disk) { state -> ui = ui.copy(saveState = state) }
    private val observedApi = object : WorkspaceApi {
        override suspend fun request(path: String, body: String?, key: String?): String {
            try {
                val result = api.request(path, body, key)
                currentCoroutineContext().ensureActive()
                ui = ui.copy(connection = Connection.CONNECTED)
                return result
            } catch (failure: ApiFailure) {
                currentCoroutineContext().ensureActive()
                ui = ui.copy(connection = if (failure.status >= 500) Connection.UNAVAILABLE else Connection.CONNECTED)
                throw failure
            } catch (failure: IOException) {
                currentCoroutineContext().ensureActive()
                ui = ui.copy(connection = Connection.OFFLINE)
                throw failure
            }
        }
    }
    var ui by mutableStateOf(WorkspaceUi())
        private set

    init { reloadLocalData() }

    fun reloadLocalData() {
        if (ui.busy) return
        ui = ui.copy(busy = true, loadingLocal = true)
        viewModelScope.launch {
            try {
                val restored = disk.run { CommandJournal(store, observedApi, disk) }
                val local = disk.run {
                    WorkspaceUi(rows = store.cachedList(), savedRows = store.cachedReviews().map { it.summary() },
                        draft = store.draft(), review = store.cachedReview(), pending = restored.pending,
                        loadingLocal = false)
                }
                journal = restored
                ui = local
                refresh()
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                ui = ui.copy(busy = false, loadingLocal = false,
                    startupError = "本机记录无法读取，写入已暂停。请保留应用数据，修复存储问题后重新读取。")
            }
        }
    }

    private fun operation(autoRefresh: Boolean = false, block: suspend () -> Unit) {
        if (ui.busy || ui.loadingLocal || ui.startupError != null) return
        ui = ui.copy(busy = true, refreshing = autoRefresh, error = null)
        val job = viewModelScope.launch {
            try { block() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: LocalDataFailure) { ui = ui.copy(error = "本机记录未能保存。输入和原提交已保留，请检查设备存储后重试。") }
            catch (failure: ApiFailure) {
                ui = ui.copy(error = if (failure.status == 409)
                    failure.message + "。输入草稿已保留，请刷新核对后再提交。"
                    else failure.message ?: "提交被拒绝，草稿已保留。")
            } catch (_: IOException) {
                ui = ui.copy(cached = true, error = "未能连接工作台。请确认电脑服务与设备转发已启动；草稿仍保留在设备。")
            } catch (failure: Exception) {
                ui = ui.copy(error = failure.message ?: "暂时无法完成，请稍后重试。")
            } finally { ui = ui.copy(busy = false, refreshing = false, pending = journal?.pending) }
        }
        if (autoRefresh) polling = job
    }

    fun refresh() = operation { refreshData() }

    fun poll() {
        if (ui.shouldPoll) operation(autoRefresh = true) { refreshData() }
    }

    fun pausePolling() { polling?.cancel(); polling = null }

    private suspend fun refreshData() {
        if (ui.page == Page.DETAIL) edits.flush()
        if (ui.page == Page.HOME && ui.savedOnly) {
            val rows = disk.run { store.cachedReviews().map { it.summary() } }
            ui = ui.copy(savedRows = rows)
            return
        }
        if (ui.checks.isEmpty()) {
            ui = ui.copy(checks = wireJson.decodeFromString<Catalog>(observedApi.request("/catalog")).checks)
        }
        if (ui.page == Page.DETAIL && ui.selectedId != null) {
            val id = ui.selectedId!!
            show(wireJson.decodeFromString(observedApi.request("/reviews/" + segment(id))), id)
        } else {
            val rows = wireJson.decodeFromString<List<ReviewSummary>>(observedApi.request("/reviews"))
            disk.run { store.saveList(rows) }
            ui = ui.copy(rows = rows, cached = false)
        }
    }

    fun showSaved(value: Boolean) {
        if (ui.busy) return
        ui = ui.copy(savedOnly = value, error = null)
        if (value) refresh()
    }

    fun checkConnection() = operation {
        ui = ui.copy(connection = Connection.CHECKING)
        val response = observedApi.request("/config")
        try {
            val config = wireJson.decodeFromString<ServerConfig>(response)
            check("mcp" in config.modes)
        } catch (_: Exception) {
            ui = ui.copy(connection = Connection.UNAVAILABLE)
            error("连接到的服务未返回有效工作台配置，请核对电脑上的服务。")
        }
    }

    fun createPage() { if (ui.editable) ui = ui.copy(page = Page.CREATE, error = null) }
    fun back() {
        if (ui.busy) return
        ui = ui.copy(page = if (ui.page in listOf(Page.SOURCE, Page.EXPORT)) Page.DETAIL else Page.HOME)
        if (ui.page == Page.HOME) refresh()
    }

    fun edit(draft: ReviewInput) {
        if (!ui.editable) return
        ui = ui.copy(draft = draft)
        edits.enqueue("draft") { store.saveDraft(draft) }
    }

    fun importDocument(read: suspend () -> ImportedDocument) = operation {
        check(ui.pending == null) { "请先确认上次提交。" }
        val imported = try { read() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: IOException) { throw IllegalArgumentException("文件无法读取，原草稿已保留。", failure) }
        val title = if (ui.draft.title.isBlank()) imported.name.substringBeforeLast('.').takeScalars(120) else ui.draft.title
        val draft = ui.draft.copy(title = title, design = imported.text)
        ui = ui.copy(draft = draft)
        edits.enqueue("draft") { store.saveDraft(draft) }
    }

    fun example() = edit(ReviewInput(
        title = "订单接口设计", design = "订单使用请求键去重；支付超时后直接重试，尚未设计结果查询。", mode = "scripted",
    ))

    fun toggleCheck(id: String) {
        val chosen = ui.draft.checkIds
        if (id in chosen) edit(ui.draft.copy(checkIds = chosen - id))
        else if (chosen.size < 8) edit(ui.draft.copy(checkIds = chosen + id))
    }

    fun retrySave() = operation { edits.flush() }

    fun create() {
        if (!ui.editable) return
        val draft = ui.draft.copy(title = ui.draft.title.trim())
        if (draft.title.isBlank() || draft.title.codePointCount(0, draft.title.length) > 120 ||
            draft.design.codePointCount(0, draft.design.length) !in 10..8000 || draft.checkIds.size !in 1..8) {
            ui = ui.copy(error = "请填写名称、10–8000 字符的设计，并选择 1–8 项检查。")
            return
        }
        send(PendingCommand(UUID.randomUUID().toString(), "/reviews", wireJson.encodeToString(draft), "create"))
    }

    fun editAnswer(id: String, text: String) {
        if (!ui.canEditAnswers || text.codePointCount(0, text.length) > 2000) return
        val reviewId = ui.selectedId ?: return
        val answers = ui.answers + (id to text)
        ui = ui.copy(answers = answers)
        edits.enqueue("answers:" + reviewId) { store.saveAnswers(reviewId, answers) }
    }

    fun answer() {
        if (!ui.editable) return
        val review = ui.review ?: return
        val answers = review.questions.associate { it.id to ui.answers[it.id].orEmpty() }
        if (answers.isEmpty() || answers.values.any { it.isBlank() || it.codePointCount(0, it.length) > 2000 }) {
            ui = ui.copy(error = "请回答每个问题；不确定时可填写‘暂不确定’。")
            return
        }
        send(PendingCommand(UUID.randomUUID().toString(), "/reviews/" + segment(review.id) + "/answers",
            wireJson.encodeToString(AnswerCommand(review.revision, answers)), "answer", review.id))
    }

    fun retry() = send(null)

    private fun send(command: PendingCommand?) = operation {
        edits.flush()
        val journal = requireNotNull(journal)
        val action = journal.pending ?: requireNotNull(command)
        journal.send(command) { review ->
            disk.run {
                store.saveReview(review)
                if (action.kind == "create") store.saveDraft(ReviewInput())
                else if (action.reviewId != null) store.saveAnswers(action.reviewId, emptyMap())
            }
            if (action.kind == "create") ui = ui.copy(draft = ReviewInput())
            else if (action.reviewId == ui.selectedId) ui = ui.copy(answers = emptyMap())
            show(review)
        }
    }

    fun open(id: String) = operation {
        edits.flush()
        val cached = disk.run { store.cachedReview(id) }
        val answers = disk.run { store.answers(id) }
        ui = ui.copy(page = Page.DETAIL, selectedId = id, review = cached, answers = answers, cached = true)
        if (!ui.savedOnly || cached == null) {
            show(wireJson.decodeFromString(observedApi.request("/reviews/" + segment(id))), id)
        }
    }

    private suspend fun show(review: ReviewSnapshot, expectedId: String? = null) {
        require(expectedId == null || review.id == expectedId) { "响应中的评审与所选记录不一致，请刷新核对。" }
        val local = disk.run {
            val previous = store.cachedReview(review.id)
            val accepted = previous?.takeIf { it.revision > review.revision } ?: review
            store.saveReview(accepted)
            Triple(accepted, store.answers(accepted.id), store.cachedReviews().map { it.summary() })
        }
        ui = ui.copy(page = Page.DETAIL, selectedId = local.first.id, review = local.first,
            answers = if (ui.selectedId == local.first.id) ui.answers else local.second,
            savedRows = local.third, cached = false)
    }

    fun source(citation: Citation) {
        if (ui.busy) return
        val source = ui.review?.sources?.get(citation.sourceId) ?: return
        ui = ui.copy(page = Page.SOURCE, source = source, quote = citation.quote)
    }

    fun export() {
        if (ui.busy) return
        val review = ui.review ?: return
        ui = ui.copy(page = Page.EXPORT, exported = review.markdown())
    }

    private fun segment(value: String) = URLEncoder.encode(value, "UTF-8")
}
