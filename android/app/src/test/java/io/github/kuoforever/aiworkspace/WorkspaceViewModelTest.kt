package io.github.kuoforever.aiworkspace

import java.io.IOException
import kotlinx.coroutines.Dispatchers
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
        override fun pending(): PendingCommand? {
            if (brokenJournal) throw LocalDataFailure(IOException("corrupt journal"))
            return command
        }
        override fun savePending(command: PendingCommand?) { this.command = command }
        override fun draft() = input
        override fun saveDraft(draft: ReviewInput) { input = draft }
        override fun answers(id: String) = emptyMap<String, String>()
        override fun saveAnswers(id: String, answers: Map<String, String>) { }
        override fun cachedReview(): ReviewSnapshot? = null
        override fun saveReview(review: ReviewSnapshot) {
            if (failSave) throw LocalDataFailure(IOException("disk full"))
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
        val vm = WorkspaceViewModel(api, store)
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
        val vm = WorkspaceViewModel(api, Store().apply { brokenCache = true })
        assertNotNull(vm.ui.startupError)
        assertTrue(api.calls.isEmpty())
    }

    @Test fun checkingConnectionDoesNotResendPendingWork() {
        val api = API().apply { offline = true }
        val store = Store().apply { command = PendingCommand("keep", "/reviews", "original", "create") }
        val vm = WorkspaceViewModel(api, store)
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
        val vm = WorkspaceViewModel(api, store)
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
}
