package io.github.kuoforever.aiworkspace

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** One ordering boundary for device storage, away from the UI thread. */
class DiskExecutor(private val dispatcher: CoroutineDispatcher = Dispatchers.IO) {
    private val lock = Mutex()
    suspend fun <T> run(work: () -> T): T = withContext(dispatcher) { lock.withLock { work() } }
}
