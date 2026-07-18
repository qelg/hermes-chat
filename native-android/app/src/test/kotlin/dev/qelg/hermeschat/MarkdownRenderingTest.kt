package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ChatItem
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownRenderingTest {
    @Test
    fun finalAssistantMessageUsesMarkdownRenderer() {
        assertTrue(shouldRenderMarkdown(ChatItem.Message("assistant", "**done**")))
    }

    @Test
    fun streamingAssistantMessageStaysPlainText() {
        assertFalse(
            shouldRenderMarkdown(
                ChatItem.Message("assistant", "**partial", pendingCanonical = true)
            )
        )
    }

    @Test
    fun userMessageStaysPlainText() {
        assertFalse(shouldRenderMarkdown(ChatItem.Message("user", "**literal**")))
    }
}
