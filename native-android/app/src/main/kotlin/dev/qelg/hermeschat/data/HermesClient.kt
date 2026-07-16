package dev.qelg.hermeschat.data

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okio.ByteString
import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

class HermesClient(
    private val config: ConnectionConfig,
    private val scope: CoroutineScope,
    private val client: OkHttpClient = OkHttpClient.Builder().cookieJar(MemoryCookieJar()).build(),
) : Closeable {
    private val json = Json { ignoreUnknownKeys = true }
    private val ids = AtomicLong()
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonObject>>()
    private val reconnect = ReconnectPolicy()
    private val _events = MutableSharedFlow<GatewayEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<GatewayEvent> = _events.asSharedFlow()
    private var socket: WebSocket? = null
    private var opening: CompletableDeferred<Unit>? = null
    private var closed = false

    suspend fun connect() {
        if (socket != null) return
        opening?.let { return it.await() }
        val ready = CompletableDeferred<Unit>()
        opening = ready
        try {
            val auth = if (config.token.isNotBlank()) "token=${config.token.urlEncode()}" else {
                login()
                val ticket = http("POST", "/api/auth/ws-ticket").string("ticket")
                    ?: error("Hermes returned no WebSocket ticket")
                "ticket=${ticket.urlEncode()}"
            }
            val httpUrl = config.normalizedBaseUrl.toHttpUrl()
            val wsUrl = httpUrl.newBuilder()
                .scheme(if (httpUrl.isHttps) "wss" else "ws")
                .encodedPath("/api/ws")
                .encodedQuery(auth)
                .build()
            client.newWebSocket(Request.Builder().url(wsUrl).build(), listener(ready))
            ready.await()
            reconnect.reset()
        } finally {
            opening = null
        }
    }

    private fun listener(ready: CompletableDeferred<Unit>) = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            socket = webSocket
            ready.complete(Unit)
        }
        override fun onMessage(webSocket: WebSocket, text: String) = handleFrame(text)
        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handleFrame(bytes.utf8())
        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = disconnected("Hermes WebSocket closed: $reason")
        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (!ready.isCompleted) ready.completeExceptionally(t)
            disconnected("Hermes WebSocket failed: ${t.message}")
        }
    }

    private fun handleFrame(frame: String) {
        val root = runCatching { json.parseToJsonElement(frame).jsonObject }.getOrNull() ?: return
        root["id"]?.jsonPrimitive?.contentOrNull?.let { id ->
            pending.remove(id)?.let { deferred ->
                root["error"]?.jsonObject?.string("message")?.let { deferred.completeExceptionally(IllegalStateException(it)) }
                    ?: deferred.complete(root["result"] as? JsonObject ?: buildJsonObject { put("data", root["result"] ?: JsonNull) })
            }
            return
        }
        ProtocolCodec.event(frame)?.let(_events::tryEmit)
    }

    private fun disconnected(message: String) {
        socket = null
        pending.values.forEach { it.completeExceptionally(IllegalStateException(message)) }
        pending.clear()
        if (!closed) scope.launch {
            _events.emit(GatewayEvent("connection.lost", null, mapOf("message" to JsonPrimitive(message))))
            delay(reconnect.nextDelayMillis())
            runCatching { connect() }.onSuccess { _events.emit(GatewayEvent("connection.restored", null, emptyMap())) }
        }
    }

    suspend fun request(method: String, params: Map<String, JsonElement> = emptyMap()): JsonObject {
        connect()
        val id = "mobile-${ids.incrementAndGet()}"
        val result = CompletableDeferred<JsonObject>()
        pending[id] = result
        check(socket?.send(ProtocolCodec.request(id, method, params).toString()) == true) { "Hermes WebSocket is disconnected" }
        return try { withTimeout(30 * 60 * 1_000L) { result.await() } } finally { pending.remove(id) }
    }

    suspend fun history(sessionId: String): List<JsonObject> = http("GET", "/api/sessions/${sessionId.urlEncode()}/messages")["messages"]
        ?.jsonArray?.mapNotNull { it as? JsonObject }.orEmpty()

    suspend fun transcribe(bytes: ByteArray, mimeType: String): String {
        val data = java.util.Base64.getEncoder().encodeToString(bytes)
        return http("POST", "/api/audio/transcribe", buildJsonObject {
            put("data_url", "data:$mimeType;base64,$data")
            put("mime_type", mimeType)
        }).string("transcript")?.trim()?.takeIf(String::isNotEmpty) ?: error("Transcription returned no text")
    }

    private suspend fun login() {
        require(config.username.isNotBlank() && config.password.isNotBlank()) { "Username and password are required" }
        http("POST", "/auth/password-login", buildJsonObject {
            put("provider", "basic"); put("username", config.username); put("password", config.password); put("next", "")
        })
    }

    private suspend fun http(method: String, path: String, body: JsonObject? = null): JsonObject = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(config.normalizedBaseUrl + path).apply {
            header("Accept", "application/json")
            if (config.token.isNotBlank()) header("X-Hermes-Session-Token", config.token)
            if (method == "POST") post((body ?: JsonObject(emptyMap())).toString().toRequestBody("application/json".toMediaType()))
        }.build()
        client.newCall(request).execute().use { response ->
            val text = response.body?.string().orEmpty()
            check(response.isSuccessful) { "Hermes HTTP ${response.code}: $text" }
            if (text.isBlank()) JsonObject(emptyMap()) else json.parseToJsonElement(text).jsonObject
        }
    }

    override fun close() { closed = true; socket?.close(1000, "App closed"); socket = null; client.dispatcher.executorService.shutdown() }
}

private class MemoryCookieJar : CookieJar {
    private val cookies = mutableMapOf<String, Cookie>()
    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) { synchronized(this.cookies) { cookies.forEach { this.cookies[it.name] = it } } }
    override fun loadForRequest(url: HttpUrl): List<Cookie> = synchronized(cookies) { cookies.values.filter { it.matches(url) } }
}

private fun String.urlEncode(): String = java.net.URLEncoder.encode(this, Charsets.UTF_8.name())
