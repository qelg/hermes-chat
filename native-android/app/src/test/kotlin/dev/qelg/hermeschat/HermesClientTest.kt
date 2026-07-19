package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ConnectionConfig
import dev.qelg.hermeschat.data.HermesClient
import dev.qelg.hermeschat.data.ModelSelection
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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
    fun historyReadsDataFieldWhenMessagesIsAbsent() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody(
                    """{"object":"list","session_id":"s1","data":[{"role":"assistant","content":"Hello","timestamp":"2026-07-17T12:00:00Z"}]}"""
                )
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client =
            HermesClient(ConnectionConfig(server.url("/").toString(), token = "test"), scope)
        try {
            val history = client.history("existing-session")
            assertEquals(1, history.size)
            assertEquals("assistant", history[0]["role"]?.jsonPrimitive?.contentOrNull)
            assertEquals("Hello", history[0]["content"]?.jsonPrimitive?.contentOrNull)
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
    fun connectNowInterruptsBackoffAndRestoresConnection() = runBlocking {
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
        server.enqueue(
            MockResponse()
                .withWebSocketUpgrade(
                    object : WebSocketListener() {
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
        val events = Channel<dev.qelg.hermeschat.data.GatewayEvent>(Channel.UNLIMITED)
        val collector = scope.launch { client.events.collect { events.send(it) } }
        try {
            client.connect()
            assertEquals("connection.lost", withTimeout(5_000) { events.receive() }.type)
            val scheduled = withTimeout(5_000) { events.receive() }
            assertEquals("connection.retry_scheduled", scheduled.type)
            assertEquals("1", scheduled.payload["seconds"]?.jsonPrimitive?.content)

            client.reconnectNow()

            assertEquals("connection.retry_started", withTimeout(5_000) { events.receive() }.type)
            assertEquals("connection.restored", withTimeout(5_000) { events.receive() }.type)
            assertEquals(2, server.requestCount)
        } finally {
            collector.cancel()
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

    @Test
    fun conversationTokenUsageTraversesOnlyCompressionParents() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "application/json")
                .setBody(
                    """{"id":"tip","parent_session_id":"root","system_prompt":"System instructions\nSecond line","input_tokens":50,"output_tokens":10,"cache_read_tokens":150,"cache_write_tokens":5,"api_call_count":1}"""
                )
        )
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "application/json")
                .setBody(
                    """{"id":"root","end_reason":"compression","input_tokens":100,"output_tokens":20,"cache_read_tokens":300,"cache_write_tokens":10,"api_call_count":2}"""
                )
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client =
            HermesClient(ConnectionConfig(server.url("/").toString(), token = "test"), scope)
        try {
            val details = client.conversationTokenDetails("tip")

            assertEquals(645L, details.usage.totalTokens)
            assertEquals("System instructions\nSecond line", details.systemPrompt)
            assertEquals("/api/sessions/tip", server.takeRequest().path)
            assertEquals("/api/sessions/root", server.takeRequest().path)
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }

    @Test
    fun toolDefinitionsUseActiveRuntimeSessionAndParseSections() = runBlocking {
        val server = MockWebServer()
        val rpcRequests = Channel<JsonObject>(Channel.UNLIMITED)
        server.enqueue(
            MockResponse()
                .withWebSocketUpgrade(
                    object : WebSocketListener() {
                        override fun onMessage(webSocket: WebSocket, text: String) {
                            val request = Json.parseToJsonElement(text).jsonObject
                            rpcRequests.trySend(request)
                            val id = request["id"]!!.jsonPrimitive.content
                            webSocket.send(
                                """{"jsonrpc":"2.0","id":"$id","result":{"sections":[{"name":"files","tools":[{"name":"read_file","description":"Read a file."},{"name":"patch","description":"Edit a file."}]}],"total":2}}"""
                            )
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
            val definitions = client.toolDefinitions("runtime-1")
            val rpc = withTimeout(5_000) { rpcRequests.receive() }

            assertEquals("tools.show", rpc["method"]!!.jsonPrimitive.content)
            assertEquals(
                "runtime-1",
                rpc["params"]!!.jsonObject["session_id"]!!.jsonPrimitive.content,
            )
            assertEquals(2, definitions.total)
            assertEquals("files", definitions.sections.single().name)
            assertEquals("read_file", definitions.sections.single().tools.first().name)
            assertEquals("Read a file.", definitions.sections.single().tools.first().description)
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }

    @Test
    fun tokenUsageUsesContextRpcAndPersistedSessionDetail() = runBlocking {
        val server = MockWebServer()
        val rpcRequests = Channel<JsonObject>(Channel.UNLIMITED)
        server.enqueue(
            MockResponse()
                .withWebSocketUpgrade(
                    object : WebSocketListener() {
                        override fun onMessage(webSocket: WebSocket, text: String) {
                            val request = Json.parseToJsonElement(text).jsonObject
                            rpcRequests.trySend(request)
                            val id = request["id"]!!.jsonPrimitive.content
                            webSocket.send(
                                """{"jsonrpc":"2.0","id":"$id","result":{"categories":[],"context_used":500,"context_max":1000,"estimated_total":500}}"""
                            )
                        }

                        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                            webSocket.close(code, reason)
                        }
                    }
                )
        )
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody(
                    """{"id":"stored-1","input_tokens":120,"output_tokens":30,"cache_read_tokens":400,"cache_write_tokens":10,"api_call_count":2}"""
                )
        )
        server.start()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val client =
            HermesClient(ConnectionConfig(server.url("/").toString(), token = "test"), scope)
        try {
            val context = client.contextBreakdown("runtime-1")
            val rpc = withTimeout(5_000) { rpcRequests.receive() }
            val cumulative = client.sessionTokenUsage("stored-1")

            assertEquals("session.context_breakdown", rpc["method"]!!.jsonPrimitive.content)
            assertEquals(
                "runtime-1",
                rpc["params"]!!.jsonObject["session_id"]!!.jsonPrimitive.content,
            )
            assertEquals(500L, context.contextUsed)
            assertEquals(560L, cumulative.totalTokens)
            assertEquals("/api/ws?token=test", server.takeRequest().path)
            assertEquals("/api/sessions/stored-1", server.takeRequest().path)
        } finally {
            client.close()
            scope.cancel()
            server.shutdown()
        }
    }
}
