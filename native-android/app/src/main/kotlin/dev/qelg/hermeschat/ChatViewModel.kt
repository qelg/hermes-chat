package dev.qelg.hermeschat

import android.app.Application
import androidx.lifecycle.*
import dev.qelg.hermeschat.data.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

@JvmInline value class ErrorMessage(val text: String)

data class ChatUiState(
    val configured: Boolean = false,
    val connecting: Boolean = false,
    val sessions: List<HermesSession> = emptyList(),
    val search: String = "",
    val selectedId: String? = null,
    val title: String = "Hermes Chat",
    val items: List<ChatItem> = emptyList(),
    val active: Boolean = false,
    val approval: ApprovalRequest? = null,
    val error: ErrorMessage? = null,
)

class ChatViewModel(application: Application, private val savedState: SavedStateHandle) :
    AndroidViewModel(application) {
    private val credentials = SecureCredentials(application)
    private val _state = MutableStateFlow(ChatUiState(selectedId = savedState["selectedId"]))
    val state: StateFlow<ChatUiState> = _state.asStateFlow()
    private var client: HermesClient? = null
    private var runtimeId: String? = null
    private var connectionJob: Job? = null
    private var eventJob: Job? = null
    private var selectionJob: Job? = null
    private var refreshJob: Job? = null
    private var connectionVersion = 0L
    private var selectionVersion = 0L

    init {
        credentials.load()?.let(::connect)
    }

    fun connect(config: ConnectionConfig) {
        if (!config.isAllowedEndpoint()) {
            _state.update {
                it.copy(
                    error =
                        ErrorMessage(
                            "Use HTTPS, or HTTP only for localhost, private LAN, or Tailscale endpoints."
                        )
                )
            }
            return
        }
        credentials.save(config)
        connectionJob?.cancel()
        eventJob?.cancel()
        selectionJob?.cancel()
        refreshJob?.cancel()
        client?.close()
        runtimeId = null
        val version = ++connectionVersion
        val next = HermesClient(config, viewModelScope)
        client = next
        _state.update {
            it.copy(
                configured = true,
                connecting = true,
                items = emptyList(),
                approval = null,
                active = false,
                error = null,
            )
        }
        eventJob =
            viewModelScope.launch {
                next.events.collect {
                    if (client === next && connectionVersion == version) handleEvent(it)
                }
            }
        connectionJob =
            viewModelScope.launch {
                runCatching {
                        next.connect()
                        refreshSessions(next, version)
                    }
                    .onSuccess {
                        if (client === next && connectionVersion == version) {
                            _state.update { it.copy(connecting = false) }
                            restoreSelection()
                        }
                    }
                    .onFailure {
                        if (client === next && connectionVersion == version) showError(it)
                    }
            }
    }

    private suspend fun restoreSelection() {
        val id = savedState.get<String>("selectedId") ?: return
        state.value.sessions.firstOrNull { it.id == id }?.let { select(it) }
    }

    fun disconnect() {
        connectionJob?.cancel()
        eventJob?.cancel()
        selectionJob?.cancel()
        refreshJob?.cancel()
        connectionVersion++
        selectionVersion++
        client?.close()
        client = null
        credentials.clear()
        runtimeId = null
        savedState["selectedId"] = null
        _state.value = ChatUiState()
    }

    fun setSearch(value: String) = _state.update { it.copy(search = value) }

    private suspend fun refreshSessions(api: HermesClient, version: Long) {
        val result = api.request("session.list", mapOf("limit" to JsonPrimitive(200)))
        if (client !== api || connectionVersion != version) return
        val sessions =
            result["sessions"]
                ?.jsonArray
                ?.mapNotNull { (it as? JsonObject)?.let(HermesSession::fromJson) }
                .orEmpty()
        _state.update { it.copy(sessions = sessions, connecting = false) }
    }

    fun refresh() {
        val api = client ?: return
        val version = connectionVersion
        refreshJob?.cancel()
        refreshJob =
            viewModelScope.launch {
                runCatching { refreshSessions(api, version) }.onFailure(::showError)
            }
    }

    private fun scheduleRefresh() {
        val api = client ?: return
        val version = connectionVersion
        if (refreshJob?.isActive == true) return
        refreshJob =
            viewModelScope.launch {
                delay(250)
                runCatching { refreshSessions(api, version) }
                    .onFailure { if (client === api) showError(it) }
            }
    }

    fun createSession() =
        viewModelScope.launch {
            val api = client ?: return@launch
            runCatching {
                    val result =
                        api.request(
                            "session.create",
                            mapOf("cols" to JsonPrimitive(96), "source" to JsonPrimitive("mobile")),
                        )
                    runtimeId =
                        result.string("session_id") ?: error("Hermes returned no session ID")
                    val stored = result.string("stored_session_id") ?: runtimeId!!
                    val session = HermesSession(stored, "Untitled session", source = "mobile")
                    savedState["selectedId"] = stored
                    _state.update {
                        it.copy(
                            selectedId = stored,
                            title = session.title,
                            items = emptyList(),
                            sessions = listOf(session) + it.sessions,
                        )
                    }
                }
                .onFailure(::showError)
        }

    fun select(session: HermesSession) {
        val api = client ?: return
        selectionJob?.cancel()
        val version = ++selectionVersion
        runtimeId = null
        savedState["selectedId"] = session.id
        _state.update {
            it.copy(
                selectedId = session.id,
                title = session.title,
                connecting = true,
                items = emptyList(),
                approval = null,
                active = false,
                error = null,
            )
        }
        selectionJob =
            viewModelScope.launch {
                runCatching {
                        val resumed =
                            api.request(
                                "session.resume",
                                mapOf(
                                    "session_id" to JsonPrimitive(session.id),
                                    "cols" to JsonPrimitive(96),
                                    "source" to JsonPrimitive("mobile"),
                                ),
                            )
                        if (selectionVersion != version || client !== api) return@runCatching
                        runtimeId =
                            resumed.string("session_id")
                                ?: error("Hermes returned no runtime session ID")
                        val history = api.history(session.id).flatMap(::messagesFromHistoryRow)
                        if (selectionVersion != version || client !== api) return@runCatching
                        _state.update {
                            it.copy(
                                items = mergeHistoryAndLive(history, it.items),
                                connecting = false,
                            )
                        }
                    }
                    .onFailure { if (selectionVersion == version && client === api) showError(it) }
            }
    }

    fun send(text: String) {
        val clean = text.trim()
        if (clean.isEmpty()) return
        viewModelScope.launch {
            if (runtimeId == null) createAndAwait()
            val id = runtimeId ?: return@launch
            _state.update {
                it.copy(
                    items = it.items + ChatItem.Message("user", clean),
                    active = true,
                    error = null,
                )
            }
            runCatching {
                    client?.request(
                        "prompt.submit",
                        mapOf("session_id" to JsonPrimitive(id), "text" to JsonPrimitive(clean)),
                    )
                }
                .onFailure {
                    _state.update { s -> s.copy(active = false) }
                    showError(it)
                }
        }
    }

    private suspend fun createAndAwait() {
        val result =
            client?.request(
                "session.create",
                mapOf("cols" to JsonPrimitive(96), "source" to JsonPrimitive("mobile")),
            ) ?: return
        runtimeId = result.string("session_id")
        val stored = result.string("stored_session_id") ?: runtimeId
        savedState["selectedId"] = stored
        _state.update {
            it.copy(selectedId = stored, title = "Untitled session", items = emptyList())
        }
    }

    fun interrupt() =
        viewModelScope.launch {
            runtimeId?.let { id ->
                runCatching {
                        client?.request(
                            "session.interrupt",
                            mapOf("session_id" to JsonPrimitive(id)),
                        )
                    }
                    .onFailure(::showError)
            }
        }

    fun approve(choice: String) =
        viewModelScope.launch {
            val request = state.value.approval ?: return@launch
            runCatching {
                    client?.request(
                        "approval.respond",
                        mapOf(
                            "session_id" to JsonPrimitive(request.sessionId),
                            "choice" to JsonPrimitive(choice),
                        ),
                    )
                }
                .onSuccess { _state.update { it.copy(approval = null) } }
                .onFailure(::showError)
        }

    fun transcribe(
        bytes: ByteArray,
        mimeType: String,
        onResult: (Result<String>) -> Unit,
        cleanup: () -> Unit,
    ) =
        viewModelScope.launch {
            val result = runCatching {
                client?.transcribe(bytes, mimeType) ?: error("Not connected")
            }
            result.onFailure(::showError)
            onResult(result)
            cleanup()
        }

    fun reportError(error: Throwable) = showError(error)

    private fun handleEvent(event: GatewayEvent) {
        val current = runtimeId
        if (event.sessionId != null && event.sessionId != current) {
            if (
                event.type in
                    setOf("session.active", "session.inactive", "message.delta", "message.complete")
            )
                scheduleRefresh()
            return
        }
        when (event.type) {
            "message.delta" ->
                appendDelta(event.payload["text"]?.jsonPrimitive?.contentOrNull.orEmpty())
            "message.complete" -> {
                val text =
                    (event.payload["text"] ?: event.payload["content"])
                        ?.jsonPrimitive
                        ?.contentOrNull
                        .orEmpty()
                _state.update {
                    it.copy(items = reconcileAssistantCompletion(it.items, text), active = false)
                }
                scheduleRefresh()
            }
            "tool.start",
            "tool.complete" -> {
                val name =
                    listOf("name", "tool", "tool_name").firstNotNullOfOrNull {
                        event.payload[it]?.jsonPrimitive?.contentOrNull
                    } ?: "tool"
                val id =
                    listOf("tool_call_id", "tool_id", "call_id", "id").firstNotNullOfOrNull {
                        event.payload[it]?.jsonPrimitive?.contentOrNull
                    }
                val state = if (event.type == "tool.start") "started" else "completed"
                val tool =
                    ChatItem.Tool(
                        id,
                        name,
                        state,
                        JsonObject(event.payload).toString(),
                        event.payload["duration_ms"]?.jsonPrimitive?.longOrNull,
                    )
                _state.update { it.copy(items = upsertTool(it.items, tool)) }
            }
            "approval.request" ->
                current?.let { id ->
                    _state.update {
                        it.copy(
                            approval =
                                ApprovalRequest(
                                    id,
                                    event.payload["command"]
                                        ?.jsonPrimitive
                                        ?.contentOrNull
                                        .orEmpty(),
                                    event.payload["description"]
                                        ?.jsonPrimitive
                                        ?.contentOrNull
                                        .orEmpty(),
                                    event.payload["allow_permanent"]
                                        ?.jsonPrimitive
                                        ?.booleanOrNull == true,
                                )
                        )
                    }
                }
            "connection.lost" ->
                _state.update {
                    it.copy(
                        connecting = true,
                        error = ErrorMessage("Connection lost; reconnecting…"),
                    )
                }
            "connection.restored" -> {
                _state.update { it.copy(connecting = false, error = null) }
                refresh()
                state.value.selectedId?.let { id ->
                    state.value.sessions.firstOrNull { it.id == id }?.let(::select)
                }
            }
            "error" ->
                showError(
                    IllegalStateException(
                        event.payload["message"]?.jsonPrimitive?.contentOrNull
                            ?: "Unknown Hermes error"
                    )
                )
        }
    }

    private fun appendDelta(text: String) {
        if (text.isEmpty()) return
        _state.update { state ->
            val items = state.items.toMutableList()
            val last = items.lastOrNull()
            if (last is ChatItem.Message && last.role == "assistant")
                items[items.lastIndex] = last.copy(text = last.text + text)
            else items += ChatItem.Message("assistant", text)
            state.copy(items = items)
        }
    }

    private fun showError(error: Throwable) =
        _state.update {
            it.copy(connecting = false, error = ErrorMessage(error.message ?: error.toString()))
        }

    override fun onCleared() {
        client?.close()
        super.onCleared()
    }
}

internal fun messagesFromHistoryRow(row: JsonObject): List<ChatItem> {
    val role = row.string("role") ?: "assistant"
    if (role == "tool")
        return listOf(
            ChatItem.Tool(
                row.string("tool_call_id"),
                row.string("tool_name") ?: row.string("name") ?: "tool",
                "completed",
                row["content"]?.toString().orEmpty(),
            )
        )
    val raw = row["content"] ?: row["text"]
    val text =
        when (raw) {
            is JsonPrimitive -> raw.contentOrNull.orEmpty()
            is JsonArray ->
                raw.mapNotNull { (it as? JsonObject)?.string("text") }.joinToString("\n")
            else -> ""
        }
    val result = mutableListOf<ChatItem>()
    if (text.isNotBlank()) result += ChatItem.Message(role, text, row.string("id"))
    (row["tool_calls"] as? JsonArray)
        ?.mapNotNull { it as? JsonObject }
        ?.forEach { call ->
            val function = call["function"] as? JsonObject
            result +=
                ChatItem.Tool(
                    call.string("id"),
                    function?.string("name") ?: call.string("name") ?: "tool",
                    "started",
                    (function?.get("arguments") ?: call["input"]).toString(),
                )
        }
    return result
}

internal fun reconcileAssistantCompletion(
    items: List<ChatItem>,
    finalText: String,
): List<ChatItem> {
    if (finalText.isBlank()) return items
    val index = items.indexOfLast { it is ChatItem.Message && it.role == "assistant" }
    if (index == -1) return items + ChatItem.Message("assistant", finalText)
    return items.toMutableList().apply {
        val current = this[index] as ChatItem.Message
        this[index] = current.copy(text = finalText)
    }
}

internal fun mergeHistoryAndLive(history: List<ChatItem>, live: List<ChatItem>): List<ChatItem> {
    val messageIds = history.mapNotNull { (it as? ChatItem.Message)?.id }.toMutableSet()
    val toolIds = history.mapNotNull { (it as? ChatItem.Tool)?.id }.toMutableSet()
    val historyTail = history.lastOrNull()
    return history +
        live.filter { item ->
            when (item) {
                is ChatItem.Message ->
                    if (item.id != null) messageIds.add(item.id)
                    else
                        historyTail !is ChatItem.Message ||
                            historyTail.role != item.role ||
                            historyTail.text != item.text
                is ChatItem.Tool -> item.id == null || toolIds.add(item.id)
                else -> true
            }
        }
}
