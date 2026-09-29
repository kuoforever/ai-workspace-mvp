package io.github.kuoforever.aiworkspace

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import java.io.IOException
import java.net.URLEncoder
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.encodeToString

enum class Page { HOME, CREATE, DETAIL, SOURCE, EXPORT }

data class WorkspaceUi(
    val page: Page = Page.HOME,
    val rows: List<ReviewSummary> = emptyList(),
    val checks: List<CheckCard> = emptyList(),
    val draft: ReviewInput = ReviewInput(),
    val review: ReviewSnapshot? = null,
    val selectedId: String? = null,
    val answers: Map<String, String> = emptyMap(),
    val source: Source? = null,
    val quote: String = "",
    val exported: String = "",
    val busy: Boolean = false,
    val cached: Boolean = true,
    val error: String? = null,
    val pending: PendingCommand? = null,
    val startupError: String? = null,
    val connection: Connection = Connection.UNKNOWN,
) { val editable: Boolean get() = !busy && pending == null && startupError == null }

class WorkspaceViewModel(private val api: WorkspaceApi, private val store: WorkspaceStore) : ViewModel() {
    private var journal: CommandJournal? = null
    private val observedApi = object : WorkspaceApi {
        override suspend fun request(path: String, body: String?, key: String?): String {
            try {
                val result = api.request(path, body, key)
                ui = ui.copy(connection = Connection.CONNECTED)
                return result
            } catch (failure: ApiFailure) {
                ui = ui.copy(connection = if (failure.status >= 500) Connection.UNAVAILABLE else Connection.CONNECTED)
                throw failure
            } catch (failure: IOException) {
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
        try {
            val restored = CommandJournal(store, observedApi)
            val state = WorkspaceUi(rows = store.cachedList(), draft = store.draft(),
                review = store.cachedReview(), pending = restored.pending)
            journal = restored
            ui = state
            refresh()
        } catch (_: Exception) {
            ui = ui.copy(startupError = "本机记录无法读取，写入已暂停。请保留应用数据，修复存储问题后重新读取。")
        }
    }

    private fun operation(block: suspend () -> Unit) {
        if (ui.busy || ui.startupError != null) return
        ui = ui.copy(busy = true, error = null)
        viewModelScope.launch {
            try { block() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: LocalDataFailure) { ui = ui.copy(error = "本机记录未能保存。输入和原提交已保留，请检查设备存储后重试。") }
            catch (failure: ApiFailure) {
                ui = ui.copy(error = if (failure.status == 409)
                    "${failure.message}。输入草稿已保留，请刷新核对后再提交。"
                    else failure.message ?: "提交被拒绝，草稿已保留。")
            } catch (_: IOException) {
                ui = ui.copy(cached = true, error = "未能连接工作台。请确认电脑服务与设备转发已启动；草稿仍保存在本机。")
            } catch (failure: Exception) {
                ui = ui.copy(error = failure.message ?: "暂时无法完成，请稍后重试。")
            } finally { ui = ui.copy(busy = false, pending = journal?.pending) }
        }
    }

    fun refresh() = operation {
        if (ui.checks.isEmpty()) {
            ui = ui.copy(checks = wireJson.decodeFromString<Catalog>(observedApi.request("/catalog")).checks)
        }
        if (ui.page == Page.DETAIL && ui.selectedId != null) {
            show(wireJson.decodeFromString(observedApi.request("/reviews/${segment(ui.selectedId!!)}")))
        } else {
            val rows = wireJson.decodeFromString<List<ReviewSummary>>(observedApi.request("/reviews"))
            store.saveList(rows)
            ui = ui.copy(rows = rows, cached = false)
        }
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
        try { store.saveDraft(draft); ui = ui.copy(draft = draft) }
        catch (_: LocalDataFailure) { ui = ui.copy(draft = draft, error = "草稿未能保存到设备，请检查存储空间；当前输入仍保留在页面。") }
    }

    fun example() = edit(ReviewInput(
        title = "订单接口设计",
        design = "订单使用请求键去重；支付超时后直接重试，尚未设计结果查询。",
        mode = "scripted",
    ))

    fun toggleCheck(id: String) {
        val chosen = ui.draft.checkIds
        if (id in chosen) edit(ui.draft.copy(checkIds = chosen - id))
        else if (chosen.size < 8) edit(ui.draft.copy(checkIds = chosen + id))
    }

    fun create() {
        val draft = ui.draft.copy(title = ui.draft.title.trim())
        if (draft.title.isBlank() || draft.title.length > 120 || draft.design.length !in 10..8000 || draft.checkIds.size !in 1..8) {
            ui = ui.copy(error = "请填写名称、10–8000 字符的设计，并选择 1–8 项检查。")
            return
        }
        send(PendingCommand(UUID.randomUUID().toString(), "/reviews", wireJson.encodeToString(draft), "create"))
    }

    fun editAnswer(id: String, text: String) {
        if (!ui.editable || text.length > 2000) return
        val reviewId = ui.selectedId ?: return
        val answers = ui.answers + (id to text)
        try { store.saveAnswers(reviewId, answers); ui = ui.copy(answers = answers) }
        catch (_: LocalDataFailure) { ui = ui.copy(answers = answers, error = "回答未能保存到设备，请检查存储空间；当前输入仍保留在页面。") }
    }

    fun answer() {
        val review = ui.review ?: return
        val answers = review.questions.associate { it.id to ui.answers[it.id].orEmpty() }
        if (answers.isEmpty() || answers.values.any { it.isBlank() || it.length > 2000 }) {
            ui = ui.copy(error = "请回答每个问题；不确定时可填写‘暂不确定’。")
            return
        }
        send(PendingCommand(
            UUID.randomUUID().toString(), "/reviews/${segment(review.id)}/answers",
            wireJson.encodeToString(AnswerCommand(review.revision, answers)), "answer", review.id,
        ))
    }

    fun retry() = send(null)

    private fun send(command: PendingCommand?) = operation {
        val journal = requireNotNull(journal)
        val action = journal.pending ?: requireNotNull(command)
        journal.send(command) { review ->
            store.saveReview(review)
            if (action.kind == "create") {
                store.saveDraft(ReviewInput())
                ui = ui.copy(draft = ReviewInput())
            } else if (action.reviewId != null) store.saveAnswers(action.reviewId, emptyMap())
            show(review)
        }
    }

    fun open(id: String) {
        if (ui.busy) return
        try {
            val cached = store.cachedReview()?.takeIf { it.id == id }
            ui = ui.copy(page = Page.DETAIL, selectedId = id, review = cached,
                answers = store.answers(id), cached = cached != null)
            refresh()
        } catch (_: LocalDataFailure) {
            ui = ui.copy(error = "本机回答或缓存无法读取，请保留应用数据后重试。")
        }
    }

    private fun show(review: ReviewSnapshot) {
        store.saveReview(review)
        ui = ui.copy(page = Page.DETAIL, selectedId = review.id, review = review,
            answers = store.answers(review.id), cached = false)
    }

    fun source(citation: Citation) {
        val source = ui.review?.sources?.get(citation.sourceId) ?: return
        ui = ui.copy(page = Page.SOURCE, source = source, quote = citation.quote)
    }

    fun export() = operation {
        val id = ui.selectedId ?: return@operation
        val text = observedApi.request("/reviews/${segment(id)}/export?format=markdown")
        ui = ui.copy(page = Page.EXPORT, exported = text)
    }

    private fun segment(value: String) = URLEncoder.encode(value, "UTF-8")
}
