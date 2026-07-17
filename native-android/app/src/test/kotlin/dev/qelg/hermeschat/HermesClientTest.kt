package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ConnectionConfig
import dev.qelg.hermeschat.data.HermesClient
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HermesClientTest {
    @Test
    fun transcriptionTimeoutExplainsHowToRecover() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"transcript":"Too late"}""")
                .setBodyDelay(150, TimeUnit.MILLISECONDS)
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client =
            HermesClient(
                ConnectionConfig(server.url("/").toString(), token = "test"),
                scope,
                transcriptionTimeoutMillis = 50,
            )
        try {
            val error =
                runCatching { client.transcribe(byteArrayOf(1, 2, 3), "audio/mp4") }
                    .exceptionOrNull()
            assertTrue(error?.message.orEmpty().contains("Voice transcription timed out"))
            assertTrue(error?.message.orEmpty().contains("try again", ignoreCase = true))
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }

    @Test
    fun transcriptionCanOutliveTheDefaultHttpReadTimeout() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"transcript":"Long recording transcript"}""")
                .setBodyDelay(150, TimeUnit.MILLISECONDS)
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val httpClient = OkHttpClient.Builder().readTimeout(50, TimeUnit.MILLISECONDS).build()
        val client =
            HermesClient(
                ConnectionConfig(server.url("/").toString(), token = "test"),
                scope,
                httpClient,
            )
        try {
            assertEquals(
                "Long recording transcript",
                client.transcribe(byteArrayOf(1, 2, 3), "audio/mp4"),
            )
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }

    @Test
    fun historyTreatsNullMessagesAsEmpty() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"messages":null}""")
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client =
            HermesClient(ConnectionConfig(server.url("/").toString(), token = "test"), scope)
        try {
            assertEquals(emptyList<JsonObject>(), client.history("existing-session"))
            assertEquals("/api/sessions/existing-session/messages", server.takeRequest().path)
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }

    @Test
    fun websocketBurstIsDeliveredWithoutDroppingEvents() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .withWebSocketUpgrade(
                    object : WebSocketListener() {
                        override fun onOpen(webSocket: WebSocket, response: Response) {
                            repeat(200) { index ->
                                webSocket.send(
                                    """{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"runtime","payload":{"text":"$index"}}}"""
                                )
                            }
                        }

                        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                            webSocket.close(code, reason)
                        }
                    }
                )
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client =
            HermesClient(ConnectionConfig(server.url("/").toString(), token = "test"), scope)
        try {
            val events = mutableListOf<dev.qelg.hermeschat.data.GatewayEvent>()
            val collector = launch(Dispatchers.Default) { client.events.take(200).toList(events) }
            client.connect()
            withTimeout(5_000) { collector.join() }
            assertEquals(
                (0 until 200).map(Int::toString),
                events.map { it.payload["text"]?.toString()?.trim('"') },
            )
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }

    @Test
    fun closeCancelsPendingReconnect() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .withWebSocketUpgrade(
                    object : WebSocketListener() {
                        override fun onOpen(webSocket: WebSocket, response: Response) {
                            webSocket.close(1012, "restart")
                        }
                    }
                )
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client =
            HermesClient(ConnectionConfig(server.url("/").toString(), token = "test"), scope)
        try {
            client.connect()
            withTimeout(5_000) { client.events.take(1).toList() }
            client.close()
            TimeUnit.MILLISECONDS.sleep(1_250)
            assertEquals(1, server.requestCount)
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }
}
