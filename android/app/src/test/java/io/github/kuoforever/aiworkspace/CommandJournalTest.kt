package io.github.kuoforever.aiworkspace

import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
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

    @Test fun cancellationAfterServerAcceptancePreservesTheRetryIdentity() = runBlocking {
        val store = MemoryStore()
        val started = CompletableDeferred<Unit>()
        val reply = CompletableDeferred<String>()
        val calls = mutableListOf<Pair<String?, String?>>()
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?): String {
                calls.add(body to key)
                if (calls.size == 1) {
                    started.complete(Unit)
                    return withContext(NonCancellable) { reply.await() }
                }
                return response
            }
        }
        val journal = CommandJournal(store, api)
        val sending = launch { journal.send(command) }
        withTimeout(3000) { started.await() }
        sending.cancel()
        reply.complete(response)
        sending.join()
        assertEquals(command, journal.pending)
        assertEquals(command, store.pending())
        journal.send()
        assertEquals(2, calls.size)
        assertTrue(calls.all { it == (command.body to command.key) })
        assertNull(store.pending())
    }

    @Test fun cancelledSubmissionKeepsReceiptDespiteALateConflict() = runBlocking {
        val store = MemoryStore()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val api = object : WorkspaceApi {
            override suspend fun request(path: String, body: String?, key: String?): String {
                started.complete(Unit)
                return withContext(NonCancellable) {
                    release.await()
                    throw ApiFailure(409, "late conflict")
                }
            }
        }
        val journal = CommandJournal(store, api)
        val submission = launch { journal.send(command) }
        withTimeout(3000) { started.await() }
        submission.cancel(); release.complete(Unit); submission.join()
        assertTrue(submission.isCancelled)
        assertEquals(command, journal.pending)
        assertEquals(command, store.pending())
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
