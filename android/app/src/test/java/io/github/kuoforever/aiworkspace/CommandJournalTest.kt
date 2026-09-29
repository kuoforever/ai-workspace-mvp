package io.github.kuoforever.aiworkspace

import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import org.junit.Assert.*
import org.junit.Test

class CommandJournalTest {
    private class MemoryStore : CommandStore {
        var value: PendingCommand? = null
        var failWrites = false
        override fun pending() = value
        override fun savePending(command: PendingCommand?) {
            if (failWrites) throw IOException("disk full")
            value = command
        }
    }

    private val command = PendingCommand("stable-request-key", "/reviews", "{\"title\":\"immutable\"}", "create")
    private val response = wireJson.encodeToString(ReviewSnapshot(
        id = "saved-on-server", revision = 1, status = "waiting_model",
        input = ReviewInput(title = "immutable"), sources = emptyMap(),
    ))

    @Test fun lostReplyAndNewClientReplayTheExactSavedCommand() = runBlocking {
        val store = MemoryStore()
        val calls = mutableListOf<Triple<String, String?, String?>>()
        val committed = mutableSetOf<String?>()
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?): String {
                calls += Triple(path, body, key)
                if (committed.add(key)) throw IOException("response lost after server commit")
                return response
            }
        }
        try { CommandJournal(store, api).send(command); fail("Expected lost reply") } catch (_: IOException) { }
        assertEquals(command, store.pending())
        val restored = CommandJournal(store, api)
        assertEquals(1, calls.size) // Loading a journal never sends automatically.
        assertEquals("saved-on-server", restored.send().id)
        assertEquals(1, committed.size)
        assertEquals(calls[0], calls[1])
        assertNull(store.pending())
    }

    @Test fun cannotReplaceAnUnconfirmedRequestWithDifferentContent() = runBlocking {
        val store = MemoryStore().apply { value = command }
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?) = error("Must not send")
        }
        try {
            CommandJournal(store, api).send(command.copy(key = "new", body = "different"))
            fail("Must preserve the unconfirmed command")
        } catch (_: IllegalStateException) { }
        assertEquals(command, store.value)
    }

    @Test fun durableWriteMustSucceedBeforeAnyNetworkRequest() = runBlocking {
        val store = MemoryStore().apply { failWrites = true }
        var sent = false
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?): String { sent = true; return response }
        }
        try { CommandJournal(store, api).send(command); fail("Expected storage error") } catch (_: IOException) { }
        assertFalse(sent)
    }

    @Test fun concreteConflictClearsCommandWhileServerFailureKeepsIt() = runBlocking {
        for (status in listOf(409, 503)) {
            val store = MemoryStore()
            val api = object : WorkspaceApi {
                override suspend fun request(path: String, body: String?, key: String?): String = throw ApiFailure(status, "failure")
            }
            try { CommandJournal(store, api).send(command); fail("Expected rejection") } catch (_: ApiFailure) { }
            if (status == 409) assertNull(store.pending()) else assertEquals(command, store.pending())
        }
    }

    @Test fun malformedSuccessResponseKeepsRetryIdentity() = runBlocking {
        val store = MemoryStore()
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?) = "truncated"
        }
        try { CommandJournal(store, api).send(command); fail("Expected decode failure") } catch (_: IllegalArgumentException) { }
        assertEquals(command, store.pending())
    }
}
