package dev.qelg.hermeschat

import android.app.Application
import androidx.lifecycle.*
import dev.qelg.hermeschat.data.*
import java.time.Instant
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.json.*

@JvmInline value class ErrorMessage(val text: String)

internal suspend fun <T> runVoiceTranscription(
    setTranscribing: (Boolean) -> Unit,
    operation: suspend () -> T,
): Result<T> {
    setTranscribing(true)
    return try {
        runCatching { operation() }
    } finally {
        setTranscribing(false)
    }
}

data class ChatUiState(
    val configured: Boolean = false,
    val connecting: Boolean = false,
    val sessions: List<HermesSession> = emptyList(),
    val search: String = "",
    val selectedId: String? = null,
    val title: String = "Hermes Chat",
    val items: List<ChatItem> = emptyList(),
    val active: Boolean = false,
    val modelCatalog: ModelCatalog = ModelCatalog(),
    val modelLoading: Boolean = false,
    val transcribing: Boolean = false,
    val approval: ApprovalRequest? = null,
    val clarify: ClarifyRequest? = null,
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
                        refreshModels(next, null, version)
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

    private suspend fun refreshModels(api: HermesClient, sessionId: String?, version: Long) {
        val catalog = api.modelOptions(sessionId)
        if (
            client !== api ||
                connectionVersion != version ||
                (sessionId != null && runtimeId != sessionId)
        )
            return
        _state.update { it.copy(modelCatalog = catalog, modelLoading = false) }
    }

    fun refreshModels() {
        val api = client ?: return
        val version = connectionVersion
        _state.update { it.copy(modelLoading = true) }
        viewModelScope.launch {
            runCatching { refreshModels(api, runtimeId, version) }
                .onFailure {
                    if (client === api) {
                        _state.update { state -> state.copy(modelLoading = false) }
                        showError(it)
                    }
                }
        }
    }

    fun selectModel(selection: ModelSelection) {
        val api = client ?: return
        val id = runtimeId ?: return
        if (state.value.active || state.value.modelLoading) return
        _state.update { it.copy(modelLoading = true, error = null) }
        viewModelScope.launch {
            runCatching { api.selectModel(id, selection) }
                .onSuccess {
                    if (client === api && runtimeId == id) {
                        _state.update { current ->
                            current.copy(
                                modelCatalog = current.modelCatalog.copy(selected = selection),
                                modelLoading = false,
                            )
                        }
                    }
                }
                .onFailure {
                    if (client === api && runtimeId == id) {
                        _state.update { current -> current.copy(modelLoading = false) }
                        showError(it)
                    }
                }
        }
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
                    val selection = state.value.modelCatalog.selected
                    val params =
                        mutableMapOf<String, JsonElement>(
                            "cols" to JsonPrimitive(96),
                            "source" to JsonPrimitive("mobile"),
                        )
                    selection?.let {
                        params["model"] = JsonPrimitive(it.model)
                        params["provider"] = JsonPrimitive(it.provider)
                    }
                    val result = api.request("session.create", params)
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
                        val resumedRuntimeId =
                            resumed.string("session_id")
                                ?: error("Hermes returned no runtime session ID")
                        runtimeId = resumedRuntimeId
                        val history = messagesFromHistoryRows(api.history(session.id))
                        if (selectionVersion != version || client !== api) return@runCatching
                        _state.update {
                            it.copy(
                                items = mergeHistoryAndLive(history, it.items),
                                connecting = false,
                            )
                        }
                        refreshModels(api, resumedRuntimeId, connectionVersion)
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
                    items = it.items + ChatItem.Message("user", clean, timestamp = Instant.now()),
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
        val selection = state.value.modelCatalog.selected
        val params =
            mutableMapOf<String, JsonElement>(
                "cols" to JsonPrimitive(96),
                "source" to JsonPrimitive("mobile"),
            )
        selection?.let {
            params["model"] = JsonPrimitive(it.model)
            params["provider"] = JsonPrimitive(it.provider)
        }
        val result = client?.request("session.create", params) ?: return
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

    fun answerClarify(text: String) {
        val clean = text.trim()
        if (clean.isEmpty()) return
        val requestId = _state.value.clarify?.requestId ?: return
        _state.update { it.copy(clarify = null) }
        viewModelScope.launch {
            runCatching {
                    client?.request(
                        "clarify.respond",
                        mapOf(
                            "request_id" to JsonPrimitive(requestId),
                            "answer" to JsonPrimitive(clean),
                        ),
                    )
                }
                .onFailure {
                    // If the response failed (e.g. expired prompt), recover by
                    // sending the answer as a regular message so the user's text
                    // isn't silently lost.
                    _state.update { it.copy(clarify = null) }
                    send(clean)
                }
        }
    }

    fun transcribe(
        bytes: ByteArray,
        mimeType: String,
        onResult: (Result<String>) -> Unit,
        cleanup: () -> Unit,
    ) =
        viewModelScope.launch {
            val result =
                runVoiceTranscription(
                    setTranscribing = { active ->
                        _state.update { it.copy(transcribing = active) }
                    },
                    operation = { client?.transcribe(bytes, mimeType) ?: error("Not connected") },
                )
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
            "session.info" -> {
                val model = event.payload["model"]?.jsonPrimitive?.contentOrNull
                val provider = event.payload["provider"]?.jsonPrimitive?.contentOrNull
                if (!model.isNullOrBlank() && !provider.isNullOrBlank()) {
                    _state.update {
                        it.copy(
                            modelCatalog =
                                it.modelCatalog.copy(selected = ModelSelection(provider, model))
                        )
                    }
                }
            }
            "clarify.request" -> {
                val parsed = parseClarifyRequest(event.payload)
                if (parsed != null) _state.update { it.copy(clarify = parsed) }
            }
            "clarify.expire" -> {
                // Server timed out or cancelled the prompt — dismiss the dialog
                val requestId = event.payload["request_id"]?.jsonPrimitive?.contentOrNull
                _state.update { current ->
                    if (requestId == null || current.clarify?.requestId == requestId)
                        current.copy(clarify = null)
                    else current
                }
            }
            "message.delta" ->
                appendDelta(event.payload["text"]?.jsonPrimitive?.contentOrNull.orEmpty())
            "message.complete" -> {
                val text =
                    (event.payload["text"] ?: event.payload["content"])
                        ?.jsonPrimitive
                        ?.contentOrNull
                        .orEmpty()
                val timestamp = event.payload.instant()
                _state.update {
                    it.copy(
                        items = reconcileAssistantCompletion(it.items, text, timestamp),
                        active = false,
                    )
                }
                scheduleRefresh()
            }
            "tool.start",
            "tool.complete",
            "tool.failed",
            "tool.error",
            "tool.cancelled" -> {
                val name =
                    listOf("name", "tool", "tool_name").firstNotNullOfOrNull {
                        event.payload[it]?.jsonPrimitive?.contentOrNull
                    } ?: "tool"
                // Clarify is an interactive prompt — the server sends a dedicated
                // clarify.request event with question + choices.  Do NOT rely on
                // tool.start here — its payload only carries a context label,
                // not the parseable arguments the dialog needs.
                if (name == "clarify") {
                    // tool.start / tool.complete / tool.failed for clarify —
                    // handled via clarify.request; just suppress the tool card
                    return
                }
                val id =
                    listOf("tool_call_id", "tool_id", "call_id", "id").firstNotNullOfOrNull {
                        event.payload[it]?.jsonPrimitive?.contentOrNull
                    }
                val state =
                    when (event.type) {
                        "tool.start" -> "running"
                        "tool.failed",
                        "tool.error" -> "failed"
                        "tool.cancelled" -> "cancelled"
                        else -> "completed"
                    }
                val eventTime = event.payload.instant() ?: Instant.now()
                val argument =
                    listOf("arguments", "args", "input", "request").firstNotNullOfOrNull {
                        event.payload[it]?.displayString()
                    }
                val result =
                    listOf("result", "output", "content").firstNotNullOfOrNull {
                        event.payload[it]?.displayString()
                    }
                val error = event.payload["error"]?.displayString()
                val batchId =
                    listOf("batch_id", "group_id", "parallel_group_id").firstNotNullOfOrNull {
                        event.payload[it]?.jsonPrimitive?.contentOrNull
                    }
                val tool =
                    ChatItem.Tool(
                        id,
                        name,
                        state,
                        arguments = if (state == "running") argument else null,
                        result = if (state == "completed") result else null,
                        error = if (state == "failed") error ?: result else null,
                        startedAt = if (state == "running") eventTime else null,
                        completedAt = if (state != "running") eventTime else null,
                        durationMs = event.payload["duration_ms"]?.jsonPrimitive?.longOrNull,
                        batchId = batchId,
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
            else items += ChatItem.Message("assistant", text, timestamp = Instant.now())
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
    val timestamp = row.instant()
    if (role == "tool")
        return listOf(
            ChatItem.Tool(
                id = row.string("tool_call_id"),
                name = row.string("tool_name") ?: row.string("name") ?: "tool",
                state = row.string("state") ?: "completed",
                result = (row["content"] ?: row["text"])?.displayString().orEmpty(),
                error = row["error"]?.displayString(),
                completedAt = timestamp,
                durationMs = row["duration_ms"]?.jsonPrimitive?.longOrNull,
                durationEstimated = false,
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
    if (text.isNotBlank())
        result += ChatItem.Message(role, text, row.string("id"), timestamp = timestamp)
    val tools =
        (row["tool_calls"] as? JsonArray)
            ?.mapNotNull { it as? JsonObject }
            ?.map { call ->
                val function = call["function"] as? JsonObject
                ChatItem.Tool(
                    id = call.string("id"),
                    name = function?.string("name") ?: call.string("name") ?: "tool",
                    state = "running",
                    arguments = (function?.get("arguments") ?: call["input"])?.displayString(),
                    startedAt = timestamp,
                    batchId = row.string("id")?.let { "history:$it" },
                )
            }
            .orEmpty()
    when (tools.size) {
        0 -> Unit
        1 -> result += tools.single()
        else ->
            result +=
                ChatItem.ParallelToolGroup(
                    tools.first().batchId ?: "history:${tools.first().id ?: result.size}",
                    tools,
                )
    }
    return result
}

internal fun messagesFromHistoryRows(rows: List<JsonObject>): List<ChatItem> =
    rows.fold(emptyList()) { items, row ->
        messagesFromHistoryRow(row).fold(items) { current, item ->
            when (item) {
                is ChatItem.Tool -> {
                    val estimated =
                        item.completedAt != null &&
                            findTool(current, item.id)?.startedAt != null &&
                            java.time.Duration.between(
                                    findTool(current, item.id)!!.startedAt,
                                    item.completedAt,
                                )
                                .toMillis() >= 100
                    upsertTool(
                        current,
                        item.copy(durationEstimated = estimated, deriveDuration = estimated),
                    )
                }
                else -> current + item
            }
        }
    }

private fun findTool(items: List<ChatItem>, id: String?): ChatItem.Tool? {
    if (id == null) return null
    items.forEach { item ->
        when (item) {
            is ChatItem.Tool -> if (item.id == id) return item
            is ChatItem.ParallelToolGroup ->
                item.tools
                    .firstOrNull { it.id == id }
                    ?.let {
                        return it
                    }
            else -> Unit
        }
    }
    return null
}

internal fun reconcileAssistantCompletion(
    items: List<ChatItem>,
    finalText: String,
    timestamp: Instant? = null,
): List<ChatItem> {
    if (finalText.isBlank()) return items
    val index = items.indexOfLast { it is ChatItem.Message && it.role == "assistant" }
    if (index == -1) return items + ChatItem.Message("assistant", finalText, timestamp = timestamp)
    return items.toMutableList().apply {
        val current = this[index] as ChatItem.Message
        this[index] = current.copy(text = finalText, timestamp = timestamp ?: current.timestamp)
    }
}

private fun ChatItem.toolIds(): Set<String> =
    when (this) {
        is ChatItem.Tool -> setOfNotNull(id)
        is ChatItem.ParallelToolGroup -> tools.mapNotNullTo(linkedSetOf()) { it.id }
        else -> emptySet()
    }

internal fun mergeHistoryAndLive(history: List<ChatItem>, live: List<ChatItem>): List<ChatItem> {
    val messageIds = history.mapNotNull { (it as? ChatItem.Message)?.id }.toMutableSet()
    val historyTail = history.lastOrNull()
    var result = history
    live.forEach { item ->
        when (item) {
            is ChatItem.Message -> {
                val shouldAdd =
                    if (item.id != null) messageIds.add(item.id)
                    else
                        historyTail !is ChatItem.Message ||
                            historyTail.role != item.role ||
                            historyTail.text != item.text
                if (shouldAdd) result += item
            }
            is ChatItem.Tool -> result = upsertTool(result, item)
            is ChatItem.ParallelToolGroup -> result = mergeParallelGroup(result, item)
            else -> result += item
        }
    }
    return result
}

private fun mergeParallelGroup(
    items: List<ChatItem>,
    live: ChatItem.ParallelToolGroup,
): List<ChatItem> {
    val liveIds = live.toolIds()
    val matching =
        items.indices.filter { index ->
            val ids = items[index].toolIds()
            ids.isNotEmpty() && ids.any(liveIds::contains)
        }
    if (matching.isEmpty()) return items + live

    var updated = items
    live.tools
        .filter { it.id != null && findTool(updated, it.id) != null }
        .forEach { updated = upsertTool(updated, it) }
    val refreshedMatching =
        updated.indices.filter { index ->
            val ids = updated[index].toolIds()
            ids.isNotEmpty() && ids.any(liveIds::contains)
        }
    val existingTools =
        refreshedMatching.flatMap { index ->
            when (val operation = updated[index]) {
                is ChatItem.Tool -> listOf(operation)
                is ChatItem.ParallelToolGroup -> operation.tools
                else -> emptyList()
            }
        }
    val byId = existingTools.mapNotNull { tool -> tool.id?.let { it to tool } }.toMap()
    val mergedTools =
        live.tools.map { tool -> tool.id?.let(byId::get) ?: tool } +
            existingTools.filter { it.id !in liveIds }
    val insertion = refreshedMatching.minOrNull() ?: updated.size
    val result = updated.toMutableList()
    refreshedMatching.sortedDescending().forEach(result::removeAt)
    result.add(insertion.coerceAtMost(result.size), live.copy(tools = mergedTools))
    return result
}

private fun Map<String, JsonElement>.instant(): Instant? =
    listOf("timestamp", "created_at", "updated_at", "time").firstNotNullOfOrNull { key ->
        this[key]?.jsonPrimitive?.let { prim ->
            prim.contentOrNull?.let { runCatching { Instant.parse(it) }.getOrNull() }
                ?: prim.doubleOrNull?.let { Instant.ofEpochMilli((it * 1000).toLong()) }
                ?: prim.longOrNull?.let {
                    if (it > 1_000_000_000_000L) Instant.ofEpochMilli(it)
                    else Instant.ofEpochSecond(it)
                }
        }
    }

private fun JsonObject.instant(): Instant? = (this as Map<String, JsonElement>).instant()

private fun JsonElement.displayString(): String =
    (this as? JsonPrimitive)?.contentOrNull ?: toString()

internal fun parseClarifyRequest(payload: Map<String, JsonElement>): ClarifyRequest? {
    val requestId = payload["request_id"]?.jsonPrimitive?.contentOrNull ?: return null
    val question = payload["question"]?.jsonPrimitive?.contentOrNull ?: return null
    val choices =
        (payload["choices"] as? JsonArray)
            ?.mapNotNull { it.jsonPrimitive?.contentOrNull }
            .orEmpty()
            .take(4)
    return ClarifyRequest(requestId, question, choices)
}
