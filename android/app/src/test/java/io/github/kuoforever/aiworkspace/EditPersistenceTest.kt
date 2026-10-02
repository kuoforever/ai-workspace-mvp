package io.github.kuoforever.aiworkspace

import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class EditPersistenceTest {
    @Test fun latestQueuedEditWinsAndFlushIsABarrier() = runTest {
        val values = mutableListOf<String>()
        var state = SaveState.SAVED
        val writer = EditPersistence(backgroundScope, DiskExecutor(UnconfinedTestDispatcher(testScheduler))) { state = it }
        writer.enqueue("draft") { values += "old" }
        writer.enqueue("draft") { values += "latest" }
        assertEquals(SaveState.SAVING, state)
        writer.flush()
        assertEquals(listOf("latest"), values)
        assertEquals(SaveState.SAVED, state)
    }
    @Test fun failureRetainsLatestValuesAndFlushRetriesThem() = runTest {
        var broken = true
        var saved = ""
        var state = SaveState.SAVED
        val writer = EditPersistence(backgroundScope, DiskExecutor(UnconfinedTestDispatcher(testScheduler))) { state = it }
        writer.enqueue("answers:one") { if (broken) throw IOException("disk full"); saved = "latest answer" }
        runCurrent()
        assertEquals(SaveState.FAILED, state)
        try { writer.flush(); fail("Expected failed flush") } catch (_: IOException) { }
        broken = false
        writer.flush()
        assertEquals("latest answer", saved)
        assertEquals(SaveState.SAVED, state)
    }
    @Test fun diskExecutorRunsStorageAwayFromCaller() = runTest {
        val caller = Thread.currentThread()
        val worker = DiskExecutor(Dispatchers.IO).run { Thread.currentThread() }
        assertNotSame(caller, worker)
    }
}
