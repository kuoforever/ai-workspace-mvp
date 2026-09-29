package io.github.kuoforever.aiworkspace

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.IOException
import kotlinx.serialization.encodeToString

interface CommandStore {
    fun pending(): PendingCommand?
    fun savePending(command: PendingCommand?)
}

class LocalDataFailure(cause: Throwable) : IOException("本机记录无法读取或保存，请保留应用数据后重试。", cause)

interface WorkspaceStore : CommandStore {
    fun draft(): ReviewInput
    fun saveDraft(draft: ReviewInput)
    fun answers(id: String): Map<String, String>
    fun saveAnswers(id: String, answers: Map<String, String>)
    fun cachedReview(): ReviewSnapshot?
    fun saveReview(review: ReviewSnapshot)
    fun cachedList(): List<ReviewSummary>
    fun saveList(rows: List<ReviewSummary>)
}

class DeviceStore(context: Context) : WorkspaceStore {
    private val preferences = context.getSharedPreferences("workspace-drafts", Context.MODE_PRIVATE)
    private val journal = AtomicFile(File(context.filesDir, "pending-command.json"))

    private inline fun <T> local(block: () -> T): T = try { block() }
        catch (failure: Exception) { throw LocalDataFailure(failure) }

    override fun pending(): PendingCommand? = local {
        if (!journal.baseFile.exists()) null
        else wireJson.decodeFromString(journal.openRead().bufferedReader().use { it.readText() })
    }

    override fun savePending(command: PendingCommand?) = local {
        // Persist JSON null too, so clearing a receipt uses the same atomic write path.
        val stream = journal.startWrite()
        try {
            stream.write(wireJson.encodeToString(command).toByteArray(Charsets.UTF_8))
            journal.finishWrite(stream)
        } catch (failure: Exception) {
            journal.failWrite(stream)
            throw failure
        }
    }

    override fun draft() = local { preferences.getString("draft", null)?.let {
        wireJson.decodeFromString<ReviewInput>(it)
    } ?: ReviewInput() }

    private fun save(name: String, value: String) = local {
        // Report write failures and finish persisting before acknowledging an edit.
        if (!preferences.edit().putString(name, value).commit()) throw IOException("Storage write failed")
    }

    override fun saveDraft(draft: ReviewInput) = save("draft", wireJson.encodeToString(draft))

    override fun answers(id: String): Map<String, String> = local {
        preferences.getString("answers:$id", null)?.let { wireJson.decodeFromString<Map<String, String>>(it) } ?: emptyMap()
    }

    override fun saveAnswers(id: String, answers: Map<String, String>) = save("answers:$id", wireJson.encodeToString(answers))

    override fun cachedReview(): ReviewSnapshot? = local {
        preferences.getString("review", null)?.let { wireJson.decodeFromString<ReviewSnapshot>(it) }
    }

    override fun saveReview(review: ReviewSnapshot) = save("review", wireJson.encodeToString(review))

    override fun cachedList(): List<ReviewSummary> = local {
        preferences.getString("list", null)?.let { wireJson.decodeFromString<List<ReviewSummary>>(it) } ?: emptyList()
    }

    override fun saveList(rows: List<ReviewSummary>) = save("list", wireJson.encodeToString(rows))
}
