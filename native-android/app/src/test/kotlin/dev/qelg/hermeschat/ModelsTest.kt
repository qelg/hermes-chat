package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ChatItem
import dev.qelg.hermeschat.data.ConnectionConfig
import dev.qelg.hermeschat.data.HermesSession
import dev.qelg.hermeschat.data.filterSessions
import dev.qelg.hermeschat.data.groupTimeline
import dev.qelg.hermeschat.data.upsertTool
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelsTest {
    @Test
    fun searchMatchesTitleAndPreviewCaseInsensitively() {
        val sessions = listOf(HermesSession("1", "Release Work", preview = "APK ready"), HermesSession("2", "Notes"))
        assertEquals(listOf("1"), filterSessions(sessions, "apk").map { it.id })
        assertEquals(listOf("1"), filterSessions(sessions, "RELEASE").map { it.id })
    }

    @Test
    fun fourConsecutiveToolsBecomeOneExpandableGroup() {
        val tools = (1..4).map { ChatItem.Tool("$it", "terminal", "started", "details") }
        val blocks = groupTimeline(tools)
        assertEquals(1, blocks.size)
        assertTrue(blocks.single() is ChatItem.ToolGroup)
        assertEquals(4, (blocks.single() as ChatItem.ToolGroup).tools.size)
    }

    @Test
    fun textSplitsToolRuns() {
        val items = listOf(ChatItem.Tool("1", "terminal", "started", ""), ChatItem.Message("assistant", "done"), ChatItem.Tool("2", "file", "started", ""))
        assertEquals(3, groupTimeline(items).size)
    }

    @Test
    fun completionReplacesMatchingToolStartInsteadOfDuplicatingIt() {
        val started = listOf<ChatItem>(ChatItem.Tool("call-1", "terminal", "started", "input"))
        val updated = upsertTool(started, ChatItem.Tool("call-1", "terminal", "completed", "output", 1250))
        assertEquals(1, updated.size)
        assertEquals("completed", (updated.single() as ChatItem.Tool).state)
        assertEquals(1250L, (updated.single() as ChatItem.Tool).durationMs)
    }

    @Test
    fun insecurePublicHttpEndpointIsRejected() {
        assertTrue(ConnectionConfig("https://example.com").isAllowedEndpoint())
        assertTrue(ConnectionConfig("http://192.168.1.2:9119").isAllowedEndpoint())
        assertTrue(ConnectionConfig("http://100.90.1.2:9119").isAllowedEndpoint())
        assertTrue(ConnectionConfig("http://server.tail1234.ts.net:9119").isAllowedEndpoint())
        assertTrue(!ConnectionConfig("http://example.com").isAllowedEndpoint())
    }
}
