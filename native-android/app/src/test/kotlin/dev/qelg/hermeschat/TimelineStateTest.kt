package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ChatItem
import dev.qelg.hermeschat.data.formatClockTime
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

class TimelineStateTest {
    @Test
    fun historyRowTreatsNullToolCallsAsNoTools() {
        val row =
            Json.parseToJsonElement(
                    """{"id":"m1","role":"assistant","content":"Hello","tool_calls":null}"""
                )
                .jsonObject
        assertEquals(
            listOf<ChatItem>(ChatItem.Message("assistant", "Hello", "m1")),
            messagesFromHistoryRow(row),
        )
    }

    @Test
    fun completionReconcilesDroppedDeltasWithCanonicalFinalText() {
        val partial = listOf<ChatItem>(ChatItem.Message("assistant", "Hel"))
        assertEquals(
            listOf<ChatItem>(ChatItem.Message("assistant", "Hello")),
            reconcileAssistantCompletion(partial, "Hello"),
        )
    }

    @Test
    fun historyCompletionPreservesEventsReceivedWhileLoading() {
        val history = listOf<ChatItem>(ChatItem.Message("user", "Question", "u1"))
        val live = listOf<ChatItem>(ChatItem.Message("assistant", "Streaming"))
        assertEquals(history + live, mergeHistoryAndLive(history, live))
    }

    @Test
    fun historyMergeDoesNotDuplicateItemsWithStableIds() {
        val message = ChatItem.Message("assistant", "Done", "m1")
        val tool = ChatItem.Tool("t1", "terminal", "completed", result = "ok")
        assertEquals(
            listOf(message, tool),
            mergeHistoryAndLive(listOf(message, tool), listOf(message, tool)),
        )
    }

    @Test
    fun historyMergeDoesNotDuplicateCanonicalCompletionReceivedWhileLoading() {
        val history = listOf<ChatItem>(ChatItem.Message("assistant", "Done", "m1"))
        val liveCompletion = listOf<ChatItem>(ChatItem.Message("assistant", "Done"))
        assertEquals(history, mergeHistoryAndLive(history, liveCompletion))
    }

    @Test
    fun historyRowsPairParallelStartsWithResultsAndEstimateMeaningfulDurations() {
        val rows =
            Json.parseToJsonElement(
                    """[
                    {"id":"m1","role":"assistant","content":"","created_at":"2026-07-17T10:00:00Z","tool_calls":[
                      {"id":"a","function":{"name":"terminal","arguments":"{\"command\":\"date\"}"}},
                      {"id":"b","function":{"name":"read_file","arguments":"{\"path\":\"x\"}"}}
                    ]},
                    {"id":"m2","role":"tool","tool_call_id":"b","tool_name":"read_file","content":"file","created_at":"2026-07-17T10:00:01Z"},
                    {"id":"m3","role":"tool","tool_call_id":"a","tool_name":"terminal","content":"Fri","created_at":"2026-07-17T10:00:02Z"}
                    ]"""
                )
                .jsonArray
                .map { it.jsonObject }
        val group = messagesFromHistoryRows(rows).single() as ChatItem.ParallelToolGroup
        assertEquals(listOf("a", "b"), group.tools.map { it.id })
        assertEquals(listOf("Fri", "file"), group.tools.map { it.result })
        assertEquals(listOf(2000L, 1000L), group.tools.map { it.durationMs })
        assertEquals(listOf(true, true), group.tools.map { it.durationEstimated })
    }

    @Test
    fun liveCompletionUpdatesMatchingPersistedStartDuringHistoryReconciliation() {
        val started =
            ChatItem.Tool(
                "t1",
                "terminal",
                "running",
                arguments = "input",
                startedAt = Instant.parse("2026-07-17T10:00:00Z"),
            )
        val completed =
            started.copy(
                state = "completed",
                result = "ok",
                completedAt = Instant.parse("2026-07-17T10:00:01Z"),
            )
        assertEquals(
            listOf(completed.copy(durationMs = 1000)),
            mergeHistoryAndLive(listOf(started), listOf(completed)),
        )
    }

    @Test
    fun partialHistoryKeepsMissingLiveParallelChildInOriginalGroup() {
        val persisted = ChatItem.Tool("a", "terminal", "running", arguments = "a")
        val live =
            ChatItem.ParallelToolGroup(
                "batch",
                listOf(persisted, ChatItem.Tool("b", "read_file", "running", arguments = "b")),
            )
        val merged = mergeHistoryAndLive(listOf(persisted), listOf(live))
        assertEquals(
            listOf("a", "b"),
            (merged.single() as ChatItem.ParallelToolGroup).tools.map { it.id },
        )
    }

    @Test
    fun databaseFlushTimestampsDoNotProduceFalsePrecision() {
        val rows =
            Json.parseToJsonElement(
                    """[
                    {"id":"m1","role":"assistant","content":"","created_at":"2026-07-17T10:00:00Z","tool_calls":[{"id":"a","function":{"name":"terminal","arguments":"{}"}}]},
                    {"id":"m2","role":"tool","tool_call_id":"a","tool_name":"terminal","content":"ok","created_at":"2026-07-17T10:00:00.001Z"}
                    ]"""
                )
                .jsonArray
                .map { it.jsonObject }
        val tool = messagesFromHistoryRows(rows).single() as ChatItem.Tool
        assertEquals(null, tool.durationMs)
        assertEquals(Instant.parse("2026-07-17T10:00:00.001Z"), tool.completedAt)
    }

    @Test
    fun historyTimestampIsPreservedAndFormattedInDeviceLocaleAndZone() {
        val row =
            Json.parseToJsonElement(
                    """{"id":"m1","role":"assistant","content":"Hello","created_at":"2026-07-17T12:37:00Z"}"""
                )
                .jsonObject
        val message = messagesFromHistoryRow(row).single() as ChatItem.Message
        assertEquals(Instant.parse("2026-07-17T12:37:00Z"), message.timestamp)
        assertEquals(
            "14:37",
            formatClockTime(message.timestamp!!, ZoneId.of("Europe/Berlin"), Locale.GERMANY),
        )
    }
}
