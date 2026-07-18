package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ContextBreakdown
import dev.qelg.hermeschat.data.CumulativeTokenUsage
import dev.qelg.hermeschat.data.LiveTokenUsage
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TokenUsageTest {
    @Test
    fun contextBreakdownSeparatesBaseConversationAndFreeCapacity() {
        val breakdown =
            ContextBreakdown.fromJson(
                Json.parseToJsonElement(
                        """{"categories":[{"id":"system_prompt","label":"System prompt","tokens":18000},{"id":"tool_definitions","label":"Tool definitions","tokens":7000},{"id":"conversation","label":"Conversation","tokens":25000}],"context_used":50000,"context_max":100000,"estimated_total":50000,"model":"test-model"}"""
                    )
                    .jsonObject
            )

        assertEquals(25_000L, breakdown.baseTokens)
        assertEquals(25_000L, breakdown.conversationTokens)
        assertEquals(50_000L, breakdown.freeTokens)
        assertEquals(50, breakdown.usedPercent)
        assertEquals("test-model", breakdown.model)
    }

    @Test
    fun cumulativeUsageIncludesCachedPromptTrafficWithoutDoubleCountingReasoning() {
        val usage =
            CumulativeTokenUsage.fromJson(
                Json.parseToJsonElement(
                        """{"input_tokens":84200,"output_tokens":52000,"cache_read_tokens":1694100,"cache_write_tokens":12000,"reasoning_tokens":18000,"api_call_count":34}"""
                    )
                    .jsonObject
            )

        assertEquals(1_790_300L, usage.processedInputTokens)
        assertEquals(1_842_300L, usage.totalTokens)
        assertEquals(95, usage.cacheHitPercent)
        assertEquals(18_000L, usage.reasoningTokens)
        assertEquals(34, usage.apiCalls)
    }

    @Test
    fun missingProviderCacheMetricsDegradeToZero() {
        val usage =
            CumulativeTokenUsage.fromJson(
                Json.parseToJsonElement("""{"input_tokens":120,"output_tokens":30}""").jsonObject
            )

        assertEquals(0L, usage.cacheReadTokens)
        assertEquals(0L, usage.cacheWriteTokens)
        assertEquals(150L, usage.totalTokens)
        assertNull(usage.cacheHitPercent)
    }

    @Test
    fun liveUsageReadsCurrentContextAndCumulativeCounters() {
        val usage =
            LiveTokenUsage.fromSessionInfo(
                Json.parseToJsonElement(
                        """{"usage":{"input":420,"output":80,"total":500,"calls":3,"context_used":20000,"context_max":100000,"context_percent":20}}"""
                    )
                    .jsonObject
            )

        assertEquals(20_000L, usage?.contextUsed)
        assertEquals(100_000L, usage?.contextMax)
        assertEquals(20, usage?.contextPercent)
        assertEquals(500L, usage?.totalTokens)
        assertEquals(3, usage?.calls)
    }

    @Test
    fun freshLiveOccupancyWinsOverAnOlderContextBreakdown() {
        val state =
            dev.qelg.hermeschat.data.TokenUsageState(
                context = ContextBreakdown(emptyList(), 40_000, 100_000, 40_000),
                live = LiveTokenUsage(65_000, 100_000, 65, 0, 0),
            )

        assertEquals(65_000L, state.currentContext?.used)
        assertEquals(100_000L, state.currentContext?.max)
        assertEquals(65, state.currentContext?.percent)
    }

    @Test
    fun compressionChainUsageAddsEachSegmentExactlyOnce() {
        val root =
            CumulativeTokenUsage.fromJson(
                Json.parseToJsonElement(
                        """{"input_tokens":100,"output_tokens":20,"cache_read_tokens":300,"cache_write_tokens":10,"api_call_count":2}"""
                    )
                    .jsonObject
            )
        val tip =
            CumulativeTokenUsage.fromJson(
                Json.parseToJsonElement(
                        """{"input_tokens":50,"output_tokens":10,"cache_read_tokens":150,"cache_write_tokens":5,"api_call_count":1}"""
                    )
                    .jsonObject
            )

        val combined = root + tip

        assertEquals(615L, combined.processedInputTokens)
        assertEquals(645L, combined.totalTokens)
        assertEquals(3, combined.apiCalls)
    }
}
