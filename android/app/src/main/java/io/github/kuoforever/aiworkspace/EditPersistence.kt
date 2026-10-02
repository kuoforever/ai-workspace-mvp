package io.github.kuoforever.aiworkspace

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

enum class SaveState(val label: String) {
    SAVED("输入已保存"), SAVING("正在保存输入…"), FAILED("输入尚未保存，仍保留在本页"),
}

/** Called on Main. Superseded edits may be skipped; the latest edit is never discarded. */
class EditPersistence(
    private val scope: CoroutineScope,
    private val disk: DiskExecutor,
    private val changed: (SaveState) -> Unit,
) {
    private data class Write(val revision: Long, val work: () -> Unit)
    private val pending = linkedMapOf<String, Write>()
    private val failedKeys = mutableSetOf<String>()
    private var revision = 0L
    private var tail: Job? = null

    fun enqueue(key: String, work: () -> Unit) {
        val write = Write(++revision, work)
        pending[key] = write
        failedKeys.remove(key)
        update()
        val previous = tail
        tail = scope.launch {
            previous?.join()
            if (pending[key] !== write) return@launch
            try { persist(key, write) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (pending[key] === write) failedKeys.add(key)
                update()
            }
        }
    }

    private fun update() = changed(if (pending.isEmpty()) SaveState.SAVED
        else if (failedKeys.isNotEmpty()) SaveState.FAILED else SaveState.SAVING)

    private suspend fun persist(key: String, write: Write) {
        disk.run(write.work)
        if (pending[key] === write) { pending.remove(key); failedKeys.remove(key) }
        update()
    }

    /** A submission must await this barrier; failures retain input and prevent network writes. */
    suspend fun flush() {
        tail?.join()
        for ((key, write) in pending.toMap()) {
            try { persist(key, write) }
            catch (failure: Exception) { failedKeys.add(key); update(); throw failure }
        }
        update()
    }
}
