package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ChatItem
import dev.qelg.hermeschat.data.HermesSession
import dev.qelg.hermeschat.data.filterSessions
import dev.qelg.hermeschat.data.groupTimeline
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
}
