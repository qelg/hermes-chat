package dev.qelg.hermeschat.data

class ReconnectPolicy {
    private var attempt = 0

    fun nextDelayMillis(): Long {
        val delay = (1_000L shl attempt.coerceAtMost(5)).coerceAtMost(30_000L)
        attempt++
        return delay
    }

    fun reset() {
        attempt = 0
    }
}
