package dev.qelg.hermeschat

import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ContextDetailDialogTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun finalDetailLineCanBeScrolledFullyIntoView() {
        composeRule.activityRule.scenario.onActivity { activity ->
            activity.setContent {
                MaterialTheme {
                    FullScreenContextDetailDialog(title = "Detail", onDismiss = {}) {
                        repeat(120) { Text("Detail line $it") }
                        Text("Final detail line")
                    }
                }
            }
        }

        composeRule.onNodeWithText("Final detail line").assertIsNotDisplayed()
        composeRule.onNodeWithText("Final detail line").performScrollTo().assertIsDisplayed()
    }
}
