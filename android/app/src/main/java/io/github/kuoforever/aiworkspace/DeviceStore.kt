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
    fun cachedReviews(): List<ReviewSnapshot> = listOfNotNull(cachedReview())
    fun cachedReview(id: String): ReviewSnapshot? = cachedReviews().firstOrNull { it.id == id }
    fun saveReview(review: ReviewSnapshot)
    fun cachedList(): List<ReviewSummary>
    fun saveList(rows: List<ReviewSummary>)
}

class DeviceStore(context: Context) : WorkspaceStore {
    private val appContext = context.applicationContext ?: context
    private val preferences by lazy { appContext.getSharedPreferences("workspace-drafts", Context.MODE_PRIVATE) }
    private val journal by lazy { AtomicFile(File(appContext.filesDir, "pending-command.json")) }

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

    override fun cachedReviews(): List<ReviewSnapshot> = local {
        val ids = preferences.getString("saved-review-ids", null)?.let {
            wireJson.decodeFromString<List<String>>(it)
        }.orEmpty()
        val saved = ids.map { id ->
            val body = preferences.getString("review:$id", null)
                ?: throw IOException("Saved report is missing")
            wireJson.decodeFromString<ReviewSnapshot>(body)
        }
        val legacy = cachedReview()
        if (legacy != null && saved.none { it.id == legacy.id }) listOf(legacy) + saved else saved
    }

    override fun saveReview(review: ReviewSnapshot) = local {
        val previous = cachedReviews()
        val accepted = previous.firstOrNull { it.id == review.id && it.revision > review.revision } ?: review
        val ids = (listOf(review.id) + previous.map { it.id }.filter { it != review.id }).take(20)
        val body = wireJson.encodeToString(accepted)
        val editor = preferences.edit().putString("review", body).putString("review:" + review.id, body)
            .putString("saved-review-ids", wireJson.encodeToString(ids))
        previous.filter { it.id in ids && it.id != review.id }.forEach {
            editor.putString("review:" + it.id, wireJson.encodeToString(it))
        }
        previous.filter { it.id !in ids }.forEach { editor.remove("review:" + it.id) }
        if (!editor.commit()) throw IOException("Storage write failed")
    }

    override fun cachedList(): List<ReviewSummary> = local {
        preferences.getString("list", null)?.let { wireJson.decodeFromString<List<ReviewSummary>>(it) } ?: emptyList()
    }

    override fun saveList(rows: List<ReviewSummary>) = save("list", wireJson.encodeToString(rows))
}
