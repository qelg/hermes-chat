package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ConnectionConfig
import dev.qelg.hermeschat.data.HermesClient
import dev.qelg.hermeschat.data.ModelSelection
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
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Test

class HermesClientTest {
    @Test
    fun modelCatalogAndSessionSwitchUseDesktopGatewayContract() = runBlocking {
        val server = MockWebServer()
        val requests = mutableListOf<JsonObject>()
        server.enqueue(
            MockResponse()
                .withWebSocketUpgrade(
                    object : WebSocketListener() {
                        override fun onMessage(webSocket: WebSocket, text: String) {
                            val request = Json.parseToJsonElement(text).jsonObject
                            synchronized(requests) { requests += request }
                            val id = request["id"]!!.jsonPrimitive.content
                            val method = request["method"]!!.jsonPrimitive.content
                            val result =
                                if (method == "model.options")
                                    """{"model":"gpt-5.6-sol","provider":"openai-codex","providers":[{"slug":"openai-codex","name":"OpenAI Codex","authenticated":true,"models":["gpt-5.6-sol"]}]}"""
                                else """{"key":"model","value":"gpt-5.6-sol"}"""
                            webSocket.send("""{"jsonrpc":"2.0","id":"$id","result":$result}""")
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
            val catalog = client.modelOptions("runtime-1")
            client.selectModel("runtime-1", ModelSelection("openai-codex", "gpt-5.6-sol"))

            assertEquals("gpt-5.6-sol", catalog.selected?.model)
            val modelParams = requests[0]["params"]!!.jsonObject
            assertEquals("runtime-1", modelParams["session_id"]!!.jsonPrimitive.content)
            val switchParams = requests[1]["params"]!!.jsonObject
            assertEquals("model", switchParams["key"]!!.jsonPrimitive.content)
            assertEquals(
                "gpt-5.6-sol --provider openai-codex --session",
                switchParams["value"]!!.jsonPrimitive.content,
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
