package io.github.kuoforever.aiworkspace

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

class ApiFailure(val status: Int, message: String) : IOException(message)

interface WorkspaceApi {
    suspend fun request(path: String, body: String? = null, key: String? = null): String
}

class LocalWorkspaceApi internal constructor(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS)
        .callTimeout(20, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false)
        // Recovery of a stale pooled socket resends the exact body/key. The
        // backend journal makes that transport recovery idempotent.
        .retryOnConnectionFailure(true).build(),
    private val endpoint: HttpUrl = "http://127.0.0.1:8765/api".toHttpUrl(),
) : WorkspaceApi {
    init { require(endpoint.scheme == "http" && endpoint.host in setOf("127.0.0.1", "localhost", "::1")) }

    override suspend fun request(path: String, body: String?, key: String?): String {
        require(path.startsWith("/") && !path.contains("..") && !path.contains('#'))
        val request = Request.Builder().url(endpoint.toString().trimEnd('/') + path)
            .header("Accept", "application/json, text/markdown")
        if (body != null) {
            require(!key.isNullOrBlank())
            request.header("Idempotency-Key", key)
                .post(body.toRequestBody("application/json; charset=utf-8".toMediaType()))
        }
        return suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request.build())
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, failure: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(failure)
                }
                override fun onResponse(call: Call, response: Response) {
                    // Reading and error decoding stay on OkHttp's worker. Always release the body.
                    try {
                        val text = response.use { result ->
                            val value = result.body?.string().orEmpty()
                            if (!result.isSuccessful) {
                                val detail = runCatching {
                                    wireJson.parseToJsonElement(value).jsonObject["detail"]?.jsonPrimitive?.content
                                }.getOrNull() ?: "工作台返回 HTTP " + result.code
                                throw ApiFailure(result.code, detail)
                            }
                            value
                        }
                        if (continuation.isActive) continuation.resume(text)
                    } catch (failure: Exception) {
                        if (continuation.isActive) continuation.resumeWithException(failure)
                    }
                }
            })
        }
    }
}
