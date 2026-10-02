package io.github.kuoforever.aiworkspace

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*

class WorkspaceApiTest {
    private val server = MockWebServer()
    private val client = OkHttpClient.Builder().followRedirects(false)
        .retryOnConnectionFailure(true).callTimeout(20, TimeUnit.SECONDS).build()
    private lateinit var api: LocalWorkspaceApi
    @Before fun setup() { server.start(); api = LocalWorkspaceApi(client, server.url("/api")) }
    @After fun teardown() {
        client.connectionPool.evictAll()
        client.dispatcher.executorService.shutdown()
        server.shutdown()
    }

    @Test fun sendsTheOriginalUtf8BodyAndKey() = runBlocking {
        server.enqueue(MockResponse().setBody("accepted"))
        val body = "{\"design\":\"订单超时😀\"}"
        assertEquals("accepted", api.request("/reviews", body, "original-key"))
        val request = server.takeRequest(3, TimeUnit.SECONDS)!!
        assertEquals("/api/reviews", request.path)
        assertEquals("POST", request.method)
        assertEquals("original-key", request.getHeader("Idempotency-Key"))
        assertEquals(body, request.body.readUtf8())
    }

    @Test fun cancellingAnInFlightRequestClosesTheCall() = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val job = launch(Dispatchers.Default) { api.request("/reviews") }
        assertNotNull(server.takeRequest(3, TimeUnit.SECONDS))
        job.cancelAndJoin()
        withTimeout(3000) { while (client.dispatcher.runningCallsCount() != 0) delay(10) }
        assertTrue(job.isCancelled)
    }

    @Test fun aLostPooledConnectionResendsOnlyTheOriginalBodyAndKey() = runBlocking {
        server.enqueue(MockResponse().setBody("ready"))
        assertEquals("ready", api.request("/reviews"))
        server.takeRequest(3, TimeUnit.SECONDS)
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        server.enqueue(MockResponse().setBody("accepted"))
        val body = "{\"design\":\"query before retry\"}"
        assertEquals("accepted", api.request("/reviews", body, "same-command"))
        val first = server.takeRequest(3, TimeUnit.SECONDS)!!
        val recovered = server.takeRequest(3, TimeUnit.SECONDS)!!
        assertEquals(first.path, recovered.path)
        assertEquals("same-command", recovered.getHeader("Idempotency-Key"))
        assertEquals(first.getHeader("Idempotency-Key"), recovered.getHeader("Idempotency-Key"))
        assertEquals(body, first.body.readUtf8())
        assertEquals(body, recovered.body.readUtf8())
        assertEquals(3, server.requestCount)
    }

    @Test fun preservesHttpRejectionsAndDoesNotFollowRedirects() = runBlocking {
        for (status in listOf(409, 503)) {
            server.enqueue(MockResponse().setResponseCode(status).setBody("{\"detail\":\"rejected\"}"))
            try { api.request("/reviews"); fail("Expected HTTP rejection") }
            catch (failure: ApiFailure) { assertEquals(status, failure.status); assertEquals("rejected", failure.message) }
        }
        server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", server.url("/elsewhere")))
        try { api.request("/reviews"); fail("Redirect must be rejected") }
        catch (failure: ApiFailure) { assertEquals(302, failure.status) }
        assertEquals(3, server.requestCount)
    }
}
