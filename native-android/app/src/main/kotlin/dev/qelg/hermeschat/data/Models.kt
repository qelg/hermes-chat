package dev.qelg.hermeschat.data

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI
import kotlinx.serialization.json.*

@JvmInline value class SessionId(val value: String)

data class HermesSession(
    val id: String,
    val title: String,
    val updatedAt: String? = null,
    val source: String? = null,
    val preview: String? = null,
    val active: Boolean = false,
) {
    companion object {
        fun fromJson(value: JsonObject): HermesSession {
            val id = value.string("id") ?: value.string("session_id") ?: ""
            return HermesSession(
                id = id,
                title = value.string("title")?.takeIf(String::isNotBlank) ?: "Untitled session",
                updatedAt =
                    value.string("updated_at")
                        ?: value.string("last_active_at")
                        ?: value.string("created_at"),
                source = value.string("source"),
                preview = value.string("preview"),
                active =
                    value["active"]?.jsonPrimitive?.booleanOrNull == true ||
                        value.string("status") in setOf("active", "running", "streaming"),
            )
        }
    }
}

fun filterSessions(sessions: List<HermesSession>, query: String): List<HermesSession> {
    val needle = query.trim().lowercase()
    if (needle.isEmpty()) return sessions
    return sessions.filter {
        it.title.lowercase().contains(needle) || it.preview?.lowercase()?.contains(needle) == true
    }
}

data class ModelSelection(val provider: String, val model: String)

data class ModelOption(val id: String, val unavailable: Boolean = false)

data class ModelProvider(val slug: String, val name: String, val models: List<ModelOption>)

data class ModelCatalog(
    val selected: ModelSelection? = null,
    val providers: List<ModelProvider> = emptyList(),
) {
    fun filtered(query: String): List<ModelProvider> {
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) return providers
        return providers.mapNotNull { provider ->
            val providerMatches =
                provider.name.lowercase().contains(needle) ||
                    provider.slug.lowercase().contains(needle)
            val models =
                if (providerMatches) provider.models
                else provider.models.filter { it.id.lowercase().contains(needle) }
            provider.takeIf { models.isNotEmpty() }?.copy(models = models)
        }
    }

    companion object {
        fun fromJson(value: JsonObject): ModelCatalog {
            val selectedModel = value.string("model")
            val selectedProvider = value.string("provider")
            val providers =
                (value["providers"] as? JsonArray)
                    ?.mapNotNull { it as? JsonObject }
                    ?.filter { it["authenticated"]?.jsonPrimitive?.booleanOrNull != false }
                    ?.mapNotNull { provider ->
                        val slug =
                            provider.string("slug")?.takeIf(String::isNotBlank)
                                ?: return@mapNotNull null
                        val unavailable =
                            (provider["unavailable_models"] as? JsonArray)
                                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                                ?.toSet()
                                .orEmpty()
                        val models =
                            (provider["models"] as? JsonArray)
                                ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                                ?.filter(String::isNotBlank)
                                ?.distinct()
                                ?.map { ModelOption(it, it in unavailable) }
                                .orEmpty()
                        if (models.isEmpty()) return@mapNotNull null
                        ModelProvider(slug, provider.string("name") ?: slug, models)
                    }
                    .orEmpty()
            return ModelCatalog(
                selected =
                    if (!selectedModel.isNullOrBlank() && !selectedProvider.isNullOrBlank())
                        ModelSelection(selectedProvider, selectedModel)
                    else null,
                providers = providers,
            )
        }
    }
}

fun modelSwitchValue(selection: ModelSelection): String =
    "${selection.model} --provider ${selection.provider} --session"

sealed interface ChatItem {
    data class Message(
        val role: String,
        val text: String,
        val id: String? = null,
        val timestamp: java.time.Instant? = null,
    ) : ChatItem

    data class Tool(
        val id: String?,
        val name: String,
        val state: String,
        val arguments: String? = null,
        val result: String? = null,
        val error: String? = null,
        val startedAt: java.time.Instant? = null,
        val completedAt: java.time.Instant? = null,
        val durationMs: Long? = null,
        val durationEstimated: Boolean = false,
        val deriveDuration: Boolean = true,
        val batchId: String? = null,
    ) : ChatItem {
        val final: Boolean
            get() = state in setOf("completed", "failed", "cancelled")

        val details: String
            get() =
                listOfNotNull(
                        arguments?.takeIf(String::isNotBlank)?.let { "Arguments\n$it" },
                        result?.takeIf(String::isNotBlank)?.let { "Result\n$it" },
                        error?.takeIf(String::isNotBlank)?.let { "Error\n$it" },
                    )
                    .joinToString("\n\n")
    }

    data class ParallelToolGroup(val id: String, val tools: List<Tool>) : ChatItem {
        val final: Boolean
            get() = tools.all(Tool::final)
    }

    data class ToolGroup(val operations: List<ChatItem>) : ChatItem {
        val callCount: Int
            get() = operations.sumOf(::toolCallCount)
    }

    data class Status(val text: String, val timestamp: java.time.Instant? = null) : ChatItem
}

private fun toolCallCount(item: ChatItem): Int =
    when (item) {
        is ChatItem.Tool -> 1
        is ChatItem.ParallelToolGroup -> item.tools.size
        else -> 0
    }

private fun isCompletedOperation(item: ChatItem): Boolean =
    when (item) {
        is ChatItem.Tool -> item.final
        is ChatItem.ParallelToolGroup -> item.final
        else -> false
    }

fun toolCountBreakdown(operations: List<ChatItem>): Map<String, Int> {
    val counts = linkedMapOf<String, Int>()
    operations.forEach { operation ->
        val tools =
            when (operation) {
                is ChatItem.Tool -> listOf(operation)
                is ChatItem.ParallelToolGroup -> operation.tools
                else -> emptyList()
            }
        tools.forEach { counts[it.name] = (counts[it.name] ?: 0) + 1 }
    }
    return counts
}

fun groupTimeline(items: List<ChatItem>, minimumGroupSize: Int = 4): List<ChatItem> {
    val result = mutableListOf<ChatItem>()
    val completed = mutableListOf<ChatItem>()
    fun flush() {
        if (completed.sumOf(::toolCallCount) >= minimumGroupSize)
            result += ChatItem.ToolGroup(completed.toList())
        else result += completed
        completed.clear()
    }
    items.forEach { item ->
        if (isCompletedOperation(item)) completed += item
        else {
            flush()
            result += item
        }
    }
    flush()
    return result
}

private fun mergeTool(started: ChatItem.Tool, update: ChatItem.Tool): ChatItem.Tool {
    if (started.final && !update.final) return started
    val startedAt = started.startedAt ?: update.startedAt
    val completedAt = update.completedAt ?: started.completedAt
    val measured =
        if (
            update.deriveDuration &&
                update.durationMs == null &&
                startedAt != null &&
                completedAt != null
        )
            java.time.Duration.between(startedAt, completedAt).toMillis().takeIf { it >= 0 }
        else null
    return update.copy(
        name = update.name.takeUnless { it == "tool" } ?: started.name,
        arguments = update.arguments ?: started.arguments,
        result = update.result ?: started.result,
        error = update.error ?: started.error,
        startedAt = startedAt,
        completedAt = completedAt,
        durationMs = update.durationMs ?: measured ?: started.durationMs,
        durationEstimated = update.durationEstimated || started.durationEstimated,
        deriveDuration = update.deriveDuration,
        batchId = update.batchId ?: started.batchId,
    )
}

private fun compatibleParallelStart(first: ChatItem.Tool, next: ChatItem.Tool): Boolean =
    !first.final &&
        !next.final &&
        (first.batchId == null || next.batchId == null || first.batchId == next.batchId)

fun upsertTool(items: List<ChatItem>, tool: ChatItem.Tool): List<ChatItem> {
    if (tool.id != null) {
        items.forEachIndexed { index, item ->
            when (item) {
                is ChatItem.Tool ->
                    if (item.id == tool.id)
                        return items.toMutableList().apply { this[index] = mergeTool(item, tool) }
                is ChatItem.ParallelToolGroup -> {
                    val child = item.tools.indexOfFirst { it.id == tool.id }
                    if (child >= 0) {
                        val updated = item.tools.toMutableList()
                        updated[child] = mergeTool(updated[child], tool)
                        return items.toMutableList().apply {
                            this[index] = item.copy(tools = updated)
                        }
                    }
                }
                else -> Unit
            }
        }
    }
    if (!tool.final) {
        when (val last = items.lastOrNull()) {
            is ChatItem.Tool ->
                if (compatibleParallelStart(last, tool)) {
                    val groupId =
                        tool.batchId ?: last.batchId ?: "parallel:${last.id ?: items.size}"
                    return items.dropLast(1) +
                        ChatItem.ParallelToolGroup(groupId, listOf(last, tool))
                }
            is ChatItem.ParallelToolGroup ->
                if (
                    !last.final &&
                        last.tools.lastOrNull()?.let { compatibleParallelStart(it, tool) } == true
                )
                    return items.dropLast(1) + last.copy(tools = last.tools + tool)
            else -> Unit
        }
    }
    return items + tool
}

fun formatClockTime(
    timestamp: java.time.Instant,
    zoneId: java.time.ZoneId = java.time.ZoneId.systemDefault(),
    locale: java.util.Locale = java.util.Locale.getDefault(),
): String =
    java.time.format.DateTimeFormatter.ofLocalizedTime(java.time.format.FormatStyle.SHORT)
        .withLocale(locale)
        .withZone(zoneId)
        .format(timestamp)

data class ApprovalRequest(
    val sessionId: String,
    val command: String,
    val description: String,
    val allowPermanent: Boolean,
)

data class ClarifyRequest(
    val question: String,
    val choices: List<String> = emptyList(),
)

data class ConnectionConfig(
    val baseUrl: String,
    val username: String = "",
    val password: String = "",
    val token: String = "",
) {
    val normalizedBaseUrl: String
        get() = baseUrl.trim().trimEnd('/')

    fun isAllowedEndpoint(): Boolean {
        val uri = runCatching { URI(normalizedBaseUrl) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase() ?: return false
        val host = uri.host?.lowercase()?.trim('[', ']')?.trimEnd('.') ?: return false
        if (
            uri.userInfo != null ||
                uri.rawQuery != null ||
                uri.rawFragment != null ||
                uri.rawPath !in setOf("", "/")
        )
            return false
        if (scheme == "https") return true
        if (scheme != "http") return false
        if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".ts.net"))
            return true
        if (!host.matches(Regex("[0-9.]+")) && ':' !in host) return false
        val address = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return false
        return when (address) {
            is Inet4Address -> {
                val octets = address.address.map { it.toInt() and 0xff }
                octets[0] == 10 ||
                    octets[0] == 127 ||
                    (octets[0] == 169 && octets[1] == 254) ||
                    (octets[0] == 172 && octets[1] in 16..31) ||
                    (octets[0] == 192 && octets[1] == 168) ||
                    (octets[0] == 100 && octets[1] in 64..127)
            }
            is Inet6Address ->
                address.isLoopbackAddress ||
                    address.isLinkLocalAddress ||
                    ((address.address[0].toInt() and 0xfe) == 0xfc)
            else -> false
        }
    }
}

fun isSafeExternalUrl(value: String): Boolean {
    val uri = runCatching { URI(value) }.getOrNull() ?: return false
    return when (uri.scheme?.lowercase()) {
        "http",
        "https" -> uri.host != null && uri.userInfo == null
        "mailto" -> uri.schemeSpecificPart?.isNotBlank() == true
        else -> false
    }
}

internal fun JsonObject.string(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
