package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ChatItem
import kotlinx.serialization.json.Json
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
        val tool = ChatItem.Tool("t1", "terminal", "completed", "ok")
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
}
