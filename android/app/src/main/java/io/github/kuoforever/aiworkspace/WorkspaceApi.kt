package io.github.kuoforever.aiworkspace

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class ApiFailure(val status: Int, message: String) : IOException(message)

interface WorkspaceApi {
    suspend fun request(path: String, body: String? = null, key: String? = null): String
}

class LocalWorkspaceApi : WorkspaceApi {
    override suspend fun request(path: String, body: String?, key: String?): String =
        withContext(Dispatchers.IO) {
            require(path.startsWith("/") && !path.contains(".."))
            // adb reverse connects device loopback to the existing loopback-only server.
            val connection = URL("http://127.0.0.1:8765/api$path").openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 5000
                connection.readTimeout = 15000
                connection.instanceFollowRedirects = false
                connection.setRequestProperty("Accept", "application/json, text/markdown")
                if (body != null) {
                    require(!key.isNullOrBlank())
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    connection.setRequestProperty("Idempotency-Key", key)
                    val bytes = body.toByteArray(Charsets.UTF_8)
                    connection.setFixedLengthStreamingMode(bytes.size)
                    connection.outputStream.use { it.write(bytes) }
                }
                val code = connection.responseCode
                val text = (if (code in 200..299) connection.inputStream else connection.errorStream)
                    ?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
                if (code !in 200..299) {
                    val detail = runCatching {
                        wireJson.parseToJsonElement(text).jsonObject["detail"]?.jsonPrimitive?.content
                    }.getOrNull() ?: "工作台返回 HTTP $code"
                    throw ApiFailure(code, detail)
                }
                text
            } finally {
                connection.disconnect()
            }
        }
}
