package dev.qelg.hermeschat.data

import kotlinx.serialization.json.*

@JvmInline value class SessionId(val value: String)

data class HermesSession(
    val id: String,
    val title: String,
    val updatedAt: String? = null,
    val source: String? = null,
    val preview: String? = null,
) {
    companion object {
        fun fromJson(value: JsonObject): HermesSession {
            val id = value.string("id") ?: value.string("session_id") ?: ""
            return HermesSession(
                id = id,
                title = value.string("title")?.takeIf(String::isNotBlank) ?: "Untitled session",
                updatedAt = value.string("updated_at") ?: value.string("last_active_at") ?: value.string("created_at"),
                source = value.string("source"),
                preview = value.string("preview"),
            )
        }
    }
}

fun filterSessions(sessions: List<HermesSession>, query: String): List<HermesSession> {
    val needle = query.trim().lowercase()
    if (needle.isEmpty()) return sessions
    return sessions.filter { it.title.lowercase().contains(needle) || it.preview?.lowercase()?.contains(needle) == true }
}

sealed interface ChatItem {
    data class Message(val role: String, val text: String, val id: String? = null) : ChatItem
    data class Tool(val id: String?, val name: String, val state: String, val details: String, val durationMs: Long? = null) : ChatItem
    data class ToolGroup(val tools: List<Tool>) : ChatItem
    data class Status(val text: String) : ChatItem
}

fun groupTimeline(items: List<ChatItem>, minimumGroupSize: Int = 4): List<ChatItem> {
    val result = mutableListOf<ChatItem>()
    val tools = mutableListOf<ChatItem.Tool>()
    fun flush() {
        if (tools.size >= minimumGroupSize) result += ChatItem.ToolGroup(tools.toList()) else result += tools
        tools.clear()
    }
    items.forEach { if (it is ChatItem.Tool) tools += it else { flush(); result += it } }
    flush()
    return result
}

data class ApprovalRequest(val sessionId: String, val command: String, val description: String, val allowPermanent: Boolean)

data class ConnectionConfig(val baseUrl: String, val username: String = "", val password: String = "", val token: String = "") {
    val normalizedBaseUrl: String get() = baseUrl.trim().trimEnd('/')
}

internal fun JsonObject.string(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
