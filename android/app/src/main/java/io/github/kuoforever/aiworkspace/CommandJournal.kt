package io.github.kuoforever.aiworkspace

class CommandJournal(private val store: CommandStore, private val api: WorkspaceApi, private val disk: DiskExecutor = DiskExecutor()) {
    var pending: PendingCommand? = store.pending()
        private set

    suspend fun send(candidate: PendingCommand? = null, accept: suspend (ReviewSnapshot) -> Unit = {}): ReviewSnapshot {
        check(pending == null || candidate == null || candidate == pending) {
            "上次提交结果尚未确认，请先重试原提交。"
        }
        val command = pending ?: requireNotNull(candidate)
        disk.run { store.savePending(command) }
        pending = command
        val response = try {
            api.request(command.path, command.body, command.key)
        } catch (failure: ApiFailure) {
            // A concrete 4xx rejection did not accept this command. Drafts live separately.
            if (failure.status in 400..499) {
                disk.run { store.savePending(null) }
                pending = null
            }
            throw failure
        }
        val review = wireJson.decodeFromString<ReviewSnapshot>(response)
        // Keep the request until both the response and its local state are saved.
        accept(review)
        // Invalid/truncated responses and I/O failures retain exactly the same request for retry.
        disk.run { store.savePending(null) }
        pending = null
        return review
    }
}
