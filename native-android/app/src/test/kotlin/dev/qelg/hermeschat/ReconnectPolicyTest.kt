package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ReconnectPolicy
import org.junit.Assert.assertEquals
import org.junit.Test

class ReconnectPolicyTest {
    @Test
    fun backoffIsBoundedAndResetsAfterConnection() {
        val policy = ReconnectPolicy()
        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 30_000L, 30_000L),
            (1..7).map { policy.nextDelayMillis() },
        )
        policy.reset()
        assertEquals(1_000L, policy.nextDelayMillis())
    }
}
