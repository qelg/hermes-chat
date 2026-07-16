package dev.qelg.hermeschat

import android.app.Application
import androidx.lifecycle.*
import dev.qelg.hermeschat.data.*
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

class ChatViewModel(application: Application, private val savedState: SavedStateHandle) : AndroidViewModel(application) {
    private val credentials = SecureCredentials(application)
    private val _state = MutableStateFlow(ChatUiState(selectedId = savedState["selectedId"]))
    val state: StateFlow<ChatUiState> = _state.asStateFlow()
    private var client: HermesClient? = null
    private var runtimeId: String? = null

    init { credentials.load()?.let(::connect) }

    fun connect(config: ConnectionConfig) {
        credentials.save(config)
        client?.close()
        val next = HermesClient(config, viewModelScope)
        client = next
        _state.update { it.copy(configured = true, connecting = true, error = null) }
        viewModelScope.launch {
            next.events.collect(::handleEvent)
        }
        viewModelScope.launch {
            runCatching { next.connect(); refreshSessions() }
                .onSuccess { _state.update { it.copy(connecting = false) }; restoreSelection() }
                .onFailure(::showError)
        }
    }

    private suspend fun restoreSelection() {
        val id = savedState.get<String>("selectedId") ?: return
        state.value.sessions.firstOrNull { it.id == id }?.let { select(it) }
    }

    fun disconnect() {
        client?.close(); client = null; credentials.clear(); runtimeId = null
        savedState["selectedId"] = null
        _state.value = ChatUiState()
    }

    fun setSearch(value: String) = _state.update { it.copy(search = value) }

    suspend fun refreshSessions() {
        val result = client?.request("session.list", mapOf("limit" to JsonPrimitive(200))) ?: return
        val sessions = result["sessions"]?.jsonArray?.mapNotNull { (it as? JsonObject)?.let(HermesSession::fromJson) }.orEmpty()
        _state.update { it.copy(sessions = sessions, connecting = false) }
    }

    fun refresh() = viewModelScope.launch { runCatching { refreshSessions() }.onFailure(::showError) }

    fun createSession() = viewModelScope.launch {
        val api = client ?: return@launch
        runCatching {
            val result = api.request("session.create", mapOf("cols" to JsonPrimitive(96), "source" to JsonPrimitive("mobile")))
            runtimeId = result.string("session_id") ?: error("Hermes returned no session ID")
            val stored = result.string("stored_session_id") ?: runtimeId!!
            val session = HermesSession(stored, "Untitled session", source = "mobile")
            savedState["selectedId"] = stored
            _state.update { it.copy(selectedId = stored, title = session.title, items = emptyList(), sessions = listOf(session) + it.sessions) }
        }.onFailure(::showError)
    }

    fun select(session: HermesSession) = viewModelScope.launch {
        val api = client ?: return@launch
        savedState["selectedId"] = session.id
        _state.update { it.copy(selectedId = session.id, title = session.title, connecting = true, items = emptyList(), error = null) }
        runCatching {
            val resumed = api.request("session.resume", mapOf("session_id" to JsonPrimitive(session.id), "cols" to JsonPrimitive(96), "source" to JsonPrimitive("mobile")))
            runtimeId = resumed.string("session_id") ?: error("Hermes returned no runtime session ID")
            val history = api.history(session.id).flatMap(::messagesFromRow)
            _state.update { it.copy(items = history, connecting = false) }
        }.onFailure(::showError)
    }

    fun send(text: String) {
        val clean = text.trim(); if (clean.isEmpty()) return
        viewModelScope.launch {
            if (runtimeId == null) createAndAwait()
            val id = runtimeId ?: return@launch
            _state.update { it.copy(items = it.items + ChatItem.Message("user", clean), active = true, error = null) }
            runCatching { client?.request("prompt.submit", mapOf("session_id" to JsonPrimitive(id), "text" to JsonPrimitive(clean))) }
                .onFailure { _state.update { s -> s.copy(active = false) }; showError(it) }
        }
    }

    private suspend fun createAndAwait() {
        val result = client?.request("session.create", mapOf("cols" to JsonPrimitive(96), "source" to JsonPrimitive("mobile"))) ?: return
        runtimeId = result.string("session_id")
        val stored = result.string("stored_session_id") ?: runtimeId
        savedState["selectedId"] = stored
        _state.update { it.copy(selectedId = stored, title = "Untitled session", items = emptyList()) }
    }

    fun interrupt() = viewModelScope.launch {
        runtimeId?.let { id -> runCatching { client?.request("session.interrupt", mapOf("session_id" to JsonPrimitive(id))) }.onFailure(::showError) }
    }

    fun approve(choice: String) = viewModelScope.launch {
        val request = state.value.approval ?: return@launch
        runCatching { client?.request("approval.respond", mapOf("session_id" to JsonPrimitive(request.sessionId), "choice" to JsonPrimitive(choice))) }
            .onSuccess { _state.update { it.copy(approval = null) } }.onFailure(::showError)
    }

    fun transcribe(bytes: ByteArray, mimeType: String, onText: (String) -> Unit) = viewModelScope.launch {
        runCatching { client?.transcribe(bytes, mimeType) ?: error("Not connected") }.onSuccess(onText).onFailure(::showError)
    }

    private fun handleEvent(event: GatewayEvent) {
        val current = runtimeId
        if (event.sessionId != null && current != null && event.sessionId != current) {
            if (event.type == "session.active" || event.type == "message.delta") refresh()
            return
        }
        when (event.type) {
            "message.delta" -> appendDelta(event.payload["text"]?.jsonPrimitive?.contentOrNull.orEmpty())
            "message.complete" -> {
                val text = (event.payload["text"] ?: event.payload["content"])?.jsonPrimitive?.contentOrNull.orEmpty()
                if (text.isNotBlank() && state.value.items.lastOrNull()?.let { it !is ChatItem.Message || it.role != "assistant" } != false) {
                    _state.update { it.copy(items = it.items + ChatItem.Message("assistant", text), active = false) }
                } else _state.update { it.copy(active = false) }
                refresh()
            }
            "tool.start", "tool.complete" -> {
                val name = listOf("name", "tool", "tool_name").firstNotNullOfOrNull { event.payload[it]?.jsonPrimitive?.contentOrNull } ?: "tool"
                val id = listOf("tool_call_id", "tool_id", "call_id", "id").firstNotNullOfOrNull { event.payload[it]?.jsonPrimitive?.contentOrNull }
                val state = if (event.type == "tool.start") "started" else "completed"
                _state.update { it.copy(items = it.items + ChatItem.Tool(id, name, state, JsonObject(event.payload).toString(), event.payload["duration_ms"]?.jsonPrimitive?.longOrNull)) }
            }
            "approval.request" -> _state.update { it.copy(approval = ApprovalRequest(current.orEmpty(), event.payload["command"]?.jsonPrimitive?.contentOrNull.orEmpty(), event.payload["description"]?.jsonPrimitive?.contentOrNull.orEmpty(), event.payload["allow_permanent"]?.jsonPrimitive?.booleanOrNull == true)) }
            "connection.lost" -> _state.update { it.copy(connecting = true, error = ErrorMessage("Connection lost; reconnecting…")) }
            "connection.restored" -> { _state.update { it.copy(connecting = false, error = null) }; state.value.selectedId?.let { id -> state.value.sessions.firstOrNull { it.id == id }?.let(::select) } }
            "error" -> showError(IllegalStateException(event.payload["message"]?.jsonPrimitive?.contentOrNull ?: "Unknown Hermes error"))
        }
    }

    private fun appendDelta(text: String) {
        if (text.isEmpty()) return
        _state.update { state ->
            val items = state.items.toMutableList()
            val last = items.lastOrNull()
            if (last is ChatItem.Message && last.role == "assistant") items[items.lastIndex] = last.copy(text = last.text + text)
            else items += ChatItem.Message("assistant", text)
            state.copy(items = items)
        }
    }

    private fun messagesFromRow(row: JsonObject): List<ChatItem> {
        val role = row.string("role") ?: "assistant"
        if (role == "tool") return listOf(ChatItem.Tool(row.string("tool_call_id"), row.string("tool_name") ?: row.string("name") ?: "tool", "completed", row["content"]?.toString().orEmpty()))
        val raw = row["content"] ?: row["text"]
        val text = when (raw) {
            is JsonPrimitive -> raw.contentOrNull.orEmpty()
            is JsonArray -> raw.mapNotNull { (it as? JsonObject)?.string("text") }.joinToString("\n")
            else -> ""
        }
        val result = mutableListOf<ChatItem>()
        if (text.isNotBlank()) result += ChatItem.Message(role, text, row.string("id"))
        row["tool_calls"]?.jsonArray?.mapNotNull { it as? JsonObject }?.forEach { call ->
            val function = call["function"] as? JsonObject
            result += ChatItem.Tool(call.string("id"), function?.string("name") ?: call.string("name") ?: "tool", "started", (function?.get("arguments") ?: call["input"]).toString())
        }
        return result
    }

    private fun showError(error: Throwable) = _state.update { it.copy(connecting = false, error = ErrorMessage(error.message ?: error.toString())) }
    override fun onCleared() { client?.close(); super.onCleared() }
}
