package dev.qelg.hermeschat.data

import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

class HermesClient(
    private val config: ConnectionConfig,
    private val scope: CoroutineScope,
    private val client: OkHttpClient = OkHttpClient.Builder().cookieJar(MemoryCookieJar()).build(),
) : Closeable {
    private val json = Json { ignoreUnknownKeys = true }
    private val ids = AtomicLong()
    private val pending = ConcurrentHashMap<String, CompletableDeferred<JsonObject>>()
    private val reconnect = ReconnectPolicy()
    private val eventChannel = Channel<GatewayEvent>(Channel.UNLIMITED)
    val events: Flow<GatewayEvent> = eventChannel.receiveAsFlow()
    private val stateLock = Any()
    private var socket: WebSocket? = null
    private var opening: CompletableDeferred<Unit>? = null
    private var generation = 0L
    private var reconnectJob: Job? = null
    @Volatile private var closed = false

    suspend fun connect() {
        check(!closed) { "Hermes client is closed" }
        val (ready, ownsOpening) =
            synchronized(stateLock) {
                if (socket != null) return
                opening?.let { it to false }
                    ?: (CompletableDeferred<Unit>().also { opening = it } to true)
            }
        if (!ownsOpening) {
            ready.await()
            return
        }
        val socketGeneration = synchronized(stateLock) { ++generation }
        try {
            val auth =
                if (config.token.isNotBlank()) {
                    "token=${config.token.urlEncode()}"
                } else {
                    login()
                    val ticket =
                        http("POST", "/api/auth/ws-ticket").string("ticket")
                            ?: error("Hermes returned no WebSocket ticket")
                    "ticket=${ticket.urlEncode()}"
                }
            check(!closed) { "Hermes client is closed" }
            val httpUrl = config.normalizedBaseUrl.toHttpUrl()
            val wsUrl =
                httpUrl
                    .newBuilder()
                    // OkHttp's WebSocket API requires an http(s) URL and performs the
                    // ws(s) upgrade internally; HttpUrl deliberately rejects ws/wss.
                    .encodedPath("/api/ws")
                    .encodedQuery(auth)
                    .build()
            client.newWebSocket(
                Request.Builder().url(wsUrl).build(),
                listener(ready, socketGeneration),
            )
            ready.await()
            reconnect.reset()
        } finally {
            synchronized(stateLock) { if (opening === ready) opening = null }
        }
    }

    private fun listener(ready: CompletableDeferred<Unit>, socketGeneration: Long) =
        object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                val accepted =
                    synchronized(stateLock) {
                        if (!closed && generation == socketGeneration) {
                            socket = webSocket
                            true
                        } else {
                            false
                        }
                    }
                if (accepted) ready.complete(Unit) else webSocket.close(1000, "Superseded")
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (isCurrent(webSocket, socketGeneration)) handleFrame(text)
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                if (isCurrent(webSocket, socketGeneration)) handleFrame(bytes.utf8())
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, reason)
                disconnected(
                    webSocket,
                    socketGeneration,
                    ready,
                    "Hermes WebSocket closing: $reason",
                )
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                disconnected(webSocket, socketGeneration, ready, "Hermes WebSocket closed: $reason")
            }

            override fun onFailure(webSocket: WebSocket, error: Throwable, response: Response?) {
                ready.completeExceptionally(error)
                disconnected(
                    webSocket,
                    socketGeneration,
                    ready,
                    "Hermes WebSocket failed: ${error.message}",
                )
            }
        }

    private fun isCurrent(webSocket: WebSocket, socketGeneration: Long): Boolean =
        synchronized(stateLock) {
            !closed && generation == socketGeneration && socket === webSocket
        }

    private fun handleFrame(frame: String) {
        val root = runCatching { json.parseToJsonElement(frame).jsonObject }.getOrNull() ?: return
        root["id"]?.jsonPrimitive?.contentOrNull?.let { id ->
            pending.remove(id)?.let { deferred ->
                root["error"]?.jsonObject?.string("message")?.let {
                    deferred.completeExceptionally(IllegalStateException(it))
                }
                    ?: deferred.complete(
                        root["result"] as? JsonObject
                            ?: buildJsonObject { put("data", root["result"] ?: JsonNull) }
                    )
            }
            return
        }
        ProtocolCodec.event(frame)?.let { eventChannel.trySend(it) }
    }

    private fun disconnected(
        webSocket: WebSocket,
        socketGeneration: Long,
        ready: CompletableDeferred<Unit>,
        message: String,
    ) {
        val shouldReconnect =
            synchronized(stateLock) {
                if (
                    closed ||
                        generation != socketGeneration ||
                        (socket != null && socket !== webSocket)
                )
                    return
                socket = null
                if (opening === ready) opening = null
                generation++
                reconnectJob?.isActive != true
            }
        pending.values.forEach { it.completeExceptionally(IllegalStateException(message)) }
        pending.clear()
        if (shouldReconnect) startReconnect(message)
    }

    private fun startReconnect(message: String) {
        reconnectJob =
            scope.launch {
                eventChannel.send(
                    GatewayEvent(
                        "connection.lost",
                        null,
                        mapOf("message" to JsonPrimitive(message)),
                    )
                )
                while (isActive && !closed) {
                    delay(reconnect.nextDelayMillis())
                    val result = runCatching { connect() }
                    if (result.isSuccess) {
                        eventChannel.send(GatewayEvent("connection.restored", null, emptyMap()))
                        break
                    }
                }
            }
    }

    suspend fun request(method: String, params: Map<String, JsonElement> = emptyMap()): JsonObject {
        connect()
        val id = "mobile-${ids.incrementAndGet()}"
        val result = CompletableDeferred<JsonObject>()
        pending[id] = result
        val sent =
            synchronized(stateLock) {
                socket?.send(ProtocolCodec.request(id, method, params).toString()) == true
            }
        if (!sent) {
            pending.remove(id)
            throw IllegalStateException("Hermes WebSocket is disconnected")
        }
        return try {
            withTimeout(30 * 60 * 1_000L) { result.await() }
        } finally {
            pending.remove(id)
        }
    }

    suspend fun history(sessionId: String): List<JsonObject> =
        (http("GET", "/api/sessions/${sessionId.urlEncode()}/messages")["messages"] as? JsonArray)
            ?.mapNotNull { it as? JsonObject }
            .orEmpty()

    suspend fun transcribe(bytes: ByteArray, mimeType: String): String {
        val data = java.util.Base64.getEncoder().encodeToString(bytes)
        return http(
                "POST",
                "/api/audio/transcribe",
                buildJsonObject {
                    put("data_url", "data:$mimeType;base64,$data")
                    put("mime_type", mimeType)
                },
            )
            .string("transcript")
            ?.trim()
            ?.takeIf(String::isNotEmpty) ?: error("Transcription returned no text")
    }

    private suspend fun login() {
        require(config.username.isNotBlank() && config.password.isNotBlank()) {
            "Username and password are required"
        }
        http(
            "POST",
            "/auth/password-login",
            buildJsonObject {
                put("provider", "basic")
                put("username", config.username)
                put("password", config.password)
                put("next", "")
            },
        )
    }

    private suspend fun http(method: String, path: String, body: JsonObject? = null): JsonObject =
        withContext(Dispatchers.IO) {
            val request =
                Request.Builder()
                    .url(config.normalizedBaseUrl + path)
                    .apply {
                        header("Accept", "application/json")
                        if (config.token.isNotBlank())
                            header("X-Hermes-Session-Token", config.token)
                        if (method == "POST")
                            post(
                                (body ?: JsonObject(emptyMap()))
                                    .toString()
                                    .toRequestBody("application/json".toMediaType())
                            )
                    }
                    .build()
            client.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                check(response.isSuccessful) { "Hermes HTTP ${response.code}: $text" }
                if (text.isBlank()) JsonObject(emptyMap())
                else json.parseToJsonElement(text).jsonObject
            }
        }

    override fun close() {
        val activeSocket =
            synchronized(stateLock) {
                if (closed) return
                closed = true
                generation++
                opening?.completeExceptionally(IllegalStateException("Hermes client is closed"))
                opening = null
                reconnectJob?.cancel()
                reconnectJob = null
                socket.also { socket = null }
            }
        activeSocket?.close(1000, "App closed")
        pending.values.forEach {
            it.completeExceptionally(IllegalStateException("Hermes client is closed"))
        }
        pending.clear()
        eventChannel.close()
        client.connectionPool.evictAll()
    }
}

private class MemoryCookieJar : CookieJar {
    private val cookies = mutableMapOf<String, Cookie>()

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        synchronized(this.cookies) { cookies.forEach { this.cookies[it.name] = it } }
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> =
        synchronized(cookies) { cookies.values.filter { it.matches(url) } }
}

private fun String.urlEncode(): String = java.net.URLEncoder.encode(this, Charsets.UTF_8.name())
