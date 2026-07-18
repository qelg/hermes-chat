package dev.qelg.hermeschat

import android.text.method.LinkMovementMethod
import android.widget.TextView
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class MarkdownTextViewTest {
    @Test
    fun selectableMarkdownTextKeepsClickableLinkMovementMethod() {
        val textView = TextView(RuntimeEnvironment.getApplication())

        configureMarkdownTextView(textView)

        assertTrue(textView.isTextSelectable)
        assertTrue(textView.movementMethod is LinkMovementMethod)
    }
}
