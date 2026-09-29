package io.github.kuoforever.aiworkspace

import android.content.Context
import android.util.AtomicFile
import java.io.File
import kotlinx.serialization.encodeToString

interface CommandStore {
    fun pending(): PendingCommand?
    fun savePending(command: PendingCommand?)
}

class DeviceStore(context: Context) : CommandStore {
    private val preferences = context.getSharedPreferences("workspace-drafts", Context.MODE_PRIVATE)
    private val journal = AtomicFile(File(context.filesDir, "pending-command.json"))

    override fun pending(): PendingCommand? =
        if (!journal.baseFile.exists()) null
        else wireJson.decodeFromString(journal.openRead().bufferedReader().use { it.readText() })

    override fun savePending(command: PendingCommand?) {
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

    fun draft() = preferences.getString("draft", null)?.let {
        wireJson.decodeFromString<ReviewInput>(it)
    } ?: ReviewInput()

    fun saveDraft(draft: ReviewInput) {
        preferences.edit().putString("draft", wireJson.encodeToString(draft)).apply()
    }

    fun answers(id: String): Map<String, String> = preferences.getString("answers:$id", null)?.let {
        wireJson.decodeFromString(it)
    } ?: emptyMap()

    fun saveAnswers(id: String, answers: Map<String, String>) {
        preferences.edit().putString("answers:$id", wireJson.encodeToString(answers)).apply()
    }

    fun cachedReview(): ReviewSnapshot? = preferences.getString("review", null)?.let {
        wireJson.decodeFromString(it)
    }

    fun saveReview(review: ReviewSnapshot) {
        preferences.edit().putString("review", wireJson.encodeToString(review)).apply()
    }

    fun cachedList(): List<ReviewSummary> = preferences.getString("list", null)?.let {
        wireJson.decodeFromString(it)
    } ?: emptyList()

    fun saveList(rows: List<ReviewSummary>) {
        preferences.edit().putString("list", wireJson.encodeToString(rows)).apply()
    }
}
