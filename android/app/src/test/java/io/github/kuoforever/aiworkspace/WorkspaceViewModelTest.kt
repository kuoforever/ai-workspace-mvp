package io.github.kuoforever.aiworkspace

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.serialization.encodeToString
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*

@OptIn(ExperimentalCoroutinesApi::class)
class WorkspaceViewModelTest {
    private val dispatcher = UnconfinedTestDispatcher()
    @Before fun setup() { Dispatchers.setMain(dispatcher) }
    @After fun teardown() { Dispatchers.resetMain() }

    private class Store : WorkspaceStore {
        var command: PendingCommand? = null
        var input = ReviewInput()
        var brokenJournal = false
        var brokenCache = false
        var failSave = false
        var failDraft = false
        var failAnswers = false
        var draftHook: (() -> Unit)? = null
        val reports = linkedMapOf<String, ReviewSnapshot>()
        val savedAnswers = mutableMapOf<String, Map<String, String>>()
        override fun pending(): PendingCommand? {
            if (brokenJournal) throw LocalDataFailure(IOException("corrupt journal"))
            return command
        }
        override fun savePending(command: PendingCommand?) { this.command = command }
        override fun draft() = input
        override fun saveDraft(draft: ReviewInput) {
            draftHook?.invoke()
            if (failDraft) throw LocalDataFailure(IOException("disk full"))
            input = draft
        }
        override fun answers(id: String) = savedAnswers[id].orEmpty()
        override fun saveAnswers(id: String, answers: Map<String, String>) {
            if (failAnswers) throw LocalDataFailure(IOException("disk full"))
            savedAnswers[id] = answers
        }
        override fun cachedReview(): ReviewSnapshot? = reports.values.lastOrNull()
        override fun cachedReviews() = reports.values.toList()
        override fun saveReview(review: ReviewSnapshot) {
            if (failSave) throw LocalDataFailure(IOException("disk full"))
            reports[review.id] = review
        }
        override fun cachedList(): List<ReviewSummary> {
            if (brokenCache) throw LocalDataFailure(IOException("corrupt cache"))
            return emptyList()
        }
        override fun saveList(rows: List<ReviewSummary>) { }
    }
    private class API : WorkspaceApi {
        val calls = mutableListOf<Triple<String, String?, String?>>()
        var offline = false
        var config = "{\"modes\":[\"mcp\",\"scripted\"]}"
        override suspend fun request(path: String, body: String?, key: String?): String {
            calls += Triple(path, body, key)
            if (offline) throw IOException("connection lost")
            return when (path) {
                "/catalog" -> "{\"checks\":[]}"
                "/config" -> config
                else -> if (body == null) "[]" else wireJson.encodeToString(ReviewSnapshot(
                    "one-review", 1, "waiting_model", ReviewInput(), emptyMap()))
            }
        }
    }

    @Test fun corruptJournalBlocksStartupWithoutErasingOrSending() {
        val store = Store().apply {
            brokenJournal = true
            command = PendingCommand("keep", "/reviews", "original", "create")
        }
        val api = API()
        val vm = WorkspaceViewModel(api, store, DiskExecutor(dispatcher))
        assertNotNull(vm.ui.startupError)
        assertFalse(vm.ui.editable)
        vm.createPage(); vm.checkConnection()
        assertEquals(Page.HOME, vm.ui.page)
        assertTrue(api.calls.isEmpty())
        assertEquals("keep", store.command?.key)
        store.brokenJournal = false
        vm.reloadLocalData()
        assertNull(vm.ui.startupError)
        assertEquals("keep", vm.ui.pending?.key)
        assertTrue(api.calls.all { it.second == null })
    }

    @Test fun corruptCacheShowsRecoveryInsteadOfCrashing() {
        val api = API()
        val vm = WorkspaceViewModel(api, Store().apply { brokenCache = true }, DiskExecutor(dispatcher))
        assertNotNull(vm.ui.startupError)
        assertTrue(api.calls.isEmpty())
    }

    @Test fun checkingConnectionDoesNotResendPendingWork() {
        val api = API().apply { offline = true }
        val store = Store().apply { command = PendingCommand("keep", "/reviews", "original", "create") }
        val vm = WorkspaceViewModel(api, store, DiskExecutor(dispatcher))
        assertEquals(Connection.OFFLINE, vm.ui.connection)
        api.offline = false
        vm.checkConnection()
        assertEquals(Connection.CONNECTED, vm.ui.connection)
        assertEquals("keep", store.command?.key)
        assertTrue(api.calls.all { it.second == null })
        api.config = "not a workspace"
        vm.checkConnection()
        assertEquals(Connection.UNAVAILABLE, vm.ui.connection)
    }

    @Test fun localResponseSaveFailureKeepsOriginalRequestForRetry() = kotlinx.coroutines.test.runTest {
        val api = API()
        val store = Store().apply { failSave = true }
        val vm = WorkspaceViewModel(api, store, DiskExecutor(dispatcher))
        vm.edit(ReviewInput(title = "Orders", design = "Retry an order after timeout."))
        vm.create()
        // The journal performs disk work on IO; wait for the view model operation.
        while (vm.ui.busy) kotlinx.coroutines.delay(1)
        assertNotNull(vm.ui.pending)
        assertEquals(Connection.CONNECTED, vm.ui.connection)
        assertTrue(vm.ui.error!!.contains("本机记录"))
        store.failSave = false
        vm.retry()
        while (vm.ui.busy) kotlinx.coroutines.delay(1)
        val writes = api.calls.filter { it.second != null }
        assertEquals(2, writes.size)
        assertEquals(writes[0], writes[1])
        assertNull(vm.ui.pending)
        assertEquals("one-review", vm.ui.review?.id)
    }

    @Test fun failedDraftSaveKeepsInputAndBlocksNetworkSubmission() {
        val api = API()
        val store = Store().apply { failDraft = true }
        val vm = WorkspaceViewModel(api, store, DiskExecutor(dispatcher))
        val input = ReviewInput(title = "Latest input", design = "Query payment status before retrying.")
        vm.edit(input)
        assertEquals(input, vm.ui.draft)
        vm.create()
        assertEquals(SaveState.FAILED, vm.ui.saveState)
        assertEquals(input, vm.ui.draft)
        assertTrue(api.calls.all { it.second == null })
        store.failDraft = false
        vm.retrySave()
        assertEquals(SaveState.SAVED, vm.ui.saveState)
        assertEquals(input, store.input)
    }

    @Test fun slowStorageDoesNotBlockTypingOrRestoreAnOlderEdit() = kotlinx.coroutines.runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val caller = Thread.currentThread()
        val store = Store().apply { draftHook = {
            assertNotSame(caller, Thread.currentThread())
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS))
        } }
        val vm = WorkspaceViewModel(API(), store)
        while (vm.ui.busy) kotlinx.coroutines.delay(1)
        try {
            vm.edit(ReviewInput(title = "first", design = "Query payment status before retrying."))
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            val latest = vm.ui.draft.copy(title = "latest")
            vm.edit(latest)
            assertEquals(latest, vm.ui.draft)
            assertEquals(SaveState.SAVING, vm.ui.saveState)
        } finally { release.countDown() }
        vm.retrySave()
        while (vm.ui.busy || vm.ui.saveState == SaveState.SAVING) kotlinx.coroutines.delay(1)
        assertEquals(SaveState.SAVED, vm.ui.saveState)
        assertEquals("latest", store.input.title)
    }

    @Test fun failedAnswerSaveIsNotOverwrittenByRefreshOrReopen() {
        val api = API()
        val store = Store().apply {
            reports["answer-review"] = ReviewSnapshot("answer-review", 2, "waiting_input", ReviewInput(),
                emptyMap(), questions = listOf(Question("q1", "How are timeouts handled?")))
            savedAnswers["answer-review"] = mapOf("q1" to "old answer")
            failAnswers = true
        }
        val vm = WorkspaceViewModel(api, store, DiskExecutor(dispatcher))
        vm.showSaved(true); vm.open("answer-review")
        vm.editAnswer("q1", "latest answer")
        val calls = api.calls.size
        vm.refresh(); vm.open("answer-review"); vm.answer()
        assertEquals("latest answer", vm.ui.answers["q1"])
        assertEquals(SaveState.FAILED, vm.ui.saveState)
        assertEquals(calls, api.calls.size)
        store.failAnswers = false
        vm.retrySave(); vm.open("answer-review")
        assertEquals("latest answer", vm.ui.answers["q1"])
        assertEquals(SaveState.SAVED, vm.ui.saveState)
    }

    @Test fun creatingFromSavedLibraryStillPollsLiveReview() {
        val vm = WorkspaceViewModel(API(), Store(), DiskExecutor(dispatcher))
        vm.showSaved(true); vm.createPage()
        vm.edit(ReviewInput(title = "Orders", design = "Query payment status before retrying."))
        vm.create()
        assertTrue(vm.ui.shouldPoll)
        assertFalse(vm.ui.copy(cached = true).shouldPoll)
    }

    @Test fun backgroundingCancelsPollingWithoutPublishingALateResult() {
        val gate = CompletableDeferred<String>()
        val response = ReviewSnapshot("poll-review", 1, "waiting_model", ReviewInput(), emptyMap())
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?): String = when {
                path == "/catalog" -> "{\"checks\":[]}"
                body != null -> wireJson.encodeToString(response)
                path == "/reviews/poll-review" -> gate.await()
                else -> "[]"
            }
        }
        val vm = WorkspaceViewModel(api, Store(), DiskExecutor(dispatcher))
        vm.createPage(); vm.example(); vm.create()
        assertTrue(vm.ui.shouldPoll)
        vm.poll()
        assertTrue(vm.ui.busy)
        vm.pausePolling()
        assertFalse(vm.ui.busy)
        assertNull(vm.ui.error)
        assertEquals(Connection.CONNECTED, vm.ui.connection)
        gate.complete(wireJson.encodeToString(response.copy(status = "completed")))
        assertEquals("waiting_model", vm.ui.review?.status)
        vm.poll()
        assertEquals("completed", vm.ui.review?.status)
    }

    @Test fun pausingPollingDoesNotCancelAManualSubmission() {
        val gate = CompletableDeferred<String>()
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?): String = when {
                path == "/catalog" -> "{\"checks\":[]}"
                body != null -> gate.await()
                else -> "[]"
            }
        }
        val store = Store()
        val vm = WorkspaceViewModel(api, store, DiskExecutor(dispatcher))
        vm.createPage(); vm.example(); vm.create()
        val original = store.command
        assertNotNull(original)
        vm.pausePolling()
        assertTrue(vm.ui.busy)
        assertEquals(original, store.command)
        gate.complete(wireJson.encodeToString(ReviewSnapshot("created", 1, "waiting_model", ReviewInput(), emptyMap())))
        assertFalse(vm.ui.busy)
        assertNull(store.command)
        assertEquals("created", vm.ui.review?.id)
    }

    @Test fun importedDraftAndOfflineReportsDoNotDependOnNetwork() {
        val store = Store()
        listOf("first", "second").forEach { id ->
            store.reports[id] = ReviewSnapshot(id, 3, "completed",
                ReviewInput(title = id, design = "Query payment status before retrying."),
                mapOf("input" to Source("Design", "Query payment status", "input.txt", "digest")),
                report = Report("Report " + id, listOf(Finding("CON-01", "risk", "reason", "advice",
                    listOf(Citation("input", "payment status"))))))
        }
        val api = API().apply { offline = true }
        val vm = WorkspaceViewModel(api, store, DiskExecutor(dispatcher))
        vm.createPage()
        vm.importDocument { ImportedDocument("design.md", "A newly imported order design.") }
        vm.retrySave()
        assertEquals("design", store.input.title)
        assertEquals("A newly imported order design.", store.input.design)
        val calls = api.calls.size
        vm.back(); vm.showSaved(true)
        for (id in listOf("first", "second")) {
            vm.open(id)
            assertEquals(id, vm.ui.review?.id)
            assertTrue(vm.ui.cached)
            vm.source(Citation("input", "payment status"))
            assertEquals("Query payment status", vm.ui.source?.text)
            vm.export()
            assertTrue(vm.ui.exported.contains("Report " + id) && vm.ui.exported.contains("> payment status"))
        }
        // Going back before selecting the saved library explicitly refreshes once.
        assertEquals(calls + 1, api.calls.size)
    }
}
