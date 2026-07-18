package dev.qelg.hermeschat

import dev.qelg.hermeschat.data.ChatItem
import dev.qelg.hermeschat.data.ConnectionConfig
import dev.qelg.hermeschat.data.DraftSubmission
import dev.qelg.hermeschat.data.HermesSession
import dev.qelg.hermeschat.data.ModelCatalog
import dev.qelg.hermeschat.data.ModelSelection
import dev.qelg.hermeschat.data.ToolValueRow
import dev.qelg.hermeschat.data.canClearDraft
import dev.qelg.hermeschat.data.filterSessions
import dev.qelg.hermeschat.data.groupTimeline
import dev.qelg.hermeschat.data.isSafeExternalUrl
import dev.qelg.hermeschat.data.modelSwitchValue
import dev.qelg.hermeschat.data.prioritizeSessionsWithDrafts
import dev.qelg.hermeschat.data.toolCountBreakdown
import dev.qelg.hermeschat.data.toolValueRows
import dev.qelg.hermeschat.data.updateDrafts
import dev.qelg.hermeschat.data.upsertTool
import java.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelsTest {
    @Test
    fun searchMatchesTitleAndPreviewCaseInsensitively() {
        val sessions =
            listOf(
                HermesSession("1", "Release Work", preview = "APK ready"),
                HermesSession("2", "Notes"),
            )
        assertEquals(listOf("1"), filterSessions(sessions, "apk").map { it.id })
        assertEquals(listOf("1"), filterSessions(sessions, "RELEASE").map { it.id })
    }

    @Test
    fun sessionsWithDraftsArePlacedFirstWithoutChangingGroupOrder() {
        val sessions =
            listOf(
                HermesSession("1", "First"),
                HermesSession("2", "Second"),
                HermesSession("3", "Third"),
                HermesSession("4", "Fourth"),
            )

        val sorted = prioritizeSessionsWithDrafts(sessions, mapOf("2" to "draft", "4" to "other"))

        assertEquals(listOf("2", "4", "1", "3"), sorted.map { it.id })
    }

    @Test
    fun blankDraftsDoNotAffectSessionOrder() {
        val sessions = listOf(HermesSession("1", "First"), HermesSession("2", "Second"))

        assertEquals(
            listOf("1", "2"),
            prioritizeSessionsWithDrafts(sessions, mapOf("2" to "  \n")).map { it.id },
        )
    }

    @Test
    fun draftUpdatesAreIsolatedPerSessionAndBlankTextRemovesOnlyThatDraft() {
        val initial = mapOf("one" to "first", "two" to "second")

        assertEquals(
            mapOf("one" to "changed", "two" to "second"),
            updateDrafts(initial, "one", "changed"),
        )
        assertEquals(mapOf("two" to "second"), updateDrafts(initial, "one", " \n "))
    }

    @Test
    fun draftClearRequiresUnchangedRevisionNamespaceAndConnection() {
        val submitted = DraftSubmission("server-a", 7, "chat", 3, "hello")

        assertTrue(canClearDraft(submitted, "server-a", 7, 3, "hello"))
        assertTrue(!canClearDraft(submitted, "server-a", 7, 5, "hello"))
        assertTrue(!canClearDraft(submitted, "server-b", 7, 3, "hello"))
        assertTrue(!canClearDraft(submitted, "server-a", 8, 3, "hello"))
    }

    @Test
    fun toolArgumentsBecomeOneCompactRowPerTopLevelArgument() {
        assertEquals(
            listOf(
                "path: /tmp/example",
                "offset: 3",
                "options: {\"recursive\":true}",
                "query: first line second line",
            ),
            toolValueRows(
                    """{"path":"/tmp/example","offset":3,"options":{"recursive":true},"query":"first line\nsecond line"}""",
                    fallbackName = "arguments",
                )
                .map(ToolValueRow::summary),
        )
    }

    @Test
    fun toolArgumentNamesAndUnicodeLineSeparatorsStayOnOneLine() {
        assertEquals(
            listOf("bad name: value", "unicode name: one two three"),
            toolValueRows(
                    """{"bad\nname":"value","unicode\u2028name":"one\u2029two\u0085three"}""",
                    fallbackName = "arguments",
                )
                .map(ToolValueRow::summary),
        )
    }

    @Test
    fun unstructuredToolArgumentsUseSingleLineFallback() {
        assertEquals(
            listOf("arguments: raw value"),
            toolValueRows("raw\nvalue", "arguments").map(ToolValueRow::summary),
        )
        assertEquals(emptyList<ToolValueRow>(), toolValueRows("  \n ", "arguments"))
    }

    @Test
    fun toolValuesKeepFullContentAndExposeCompactSummaries() {
        val rows =
            toolValueRows(
                """{"message":"first\nsecond","payload":{"ok":true}}""",
                fallbackName = "answer",
            )

        assertEquals(
            listOf(
                ToolValueRow("message", "first\nsecond"),
                ToolValueRow("payload", "{\"ok\":true}"),
            ),
            rows,
        )
        assertEquals(
            listOf("message: first second", "payload: {\"ok\":true}"),
            rows.map { it.summary },
        )
    }

    @Test
    fun unstructuredToolValueUsesLabelButPreservesDetailContent() {
        val rows = toolValueRows("line one\nline two", fallbackName = "answer")

        assertEquals(listOf(ToolValueRow("answer", "line one\nline two")), rows)
        assertEquals("answer: line one line two", rows.single().summary)
    }

    @Test
    fun fourConsecutiveToolsBecomeOneExpandableGroup() {
        val tools = (1..4).map { ChatItem.Tool("$it", "terminal", "completed", result = "details") }
        val blocks = groupTimeline(tools)
        assertEquals(1, blocks.size)
        assertTrue(blocks.single() is ChatItem.ToolGroup)
        assertEquals(4, (blocks.single() as ChatItem.ToolGroup).callCount)
    }

    @Test
    fun textSplitsToolRuns() {
        val items =
            listOf(
                ChatItem.Tool("1", "terminal", "completed", result = ""),
                ChatItem.Message("assistant", "done"),
                ChatItem.Tool("2", "file", "completed", result = ""),
            )
        assertEquals(3, groupTimeline(items).size)
    }

    @Test
    fun completionReplacesMatchingToolStartInsteadOfDuplicatingIt() {
        val startedAt = Instant.parse("2026-07-17T10:00:00Z")
        val started =
            listOf<ChatItem>(
                ChatItem.Tool(
                    "call-1",
                    "terminal",
                    "running",
                    arguments = "input",
                    startedAt = startedAt,
                )
            )
        val updated =
            upsertTool(
                started,
                ChatItem.Tool(
                    "call-1",
                    "terminal",
                    "completed",
                    result = "output",
                    completedAt = Instant.parse("2026-07-17T10:00:01.250Z"),
                ),
            )
        assertEquals(1, updated.size)
        val completed = updated.single() as ChatItem.Tool
        assertEquals("completed", completed.state)
        assertEquals(1250L, completed.durationMs)
        assertEquals("input", completed.arguments)
        assertEquals("output", completed.result)
    }

    @Test
    fun overlappingStartsBecomeOnePersistentParallelGroup() {
        val first =
            ChatItem.Tool("1", "terminal", "running", arguments = "one", startedAt = Instant.EPOCH)
        val second =
            ChatItem.Tool("2", "read_file", "running", arguments = "two", startedAt = Instant.EPOCH)
        val started = upsertTool(upsertTool(emptyList(), first), second)
        val group = started.single() as ChatItem.ParallelToolGroup
        assertEquals(listOf("1", "2"), group.tools.map { it.id })

        val partiallyComplete =
            upsertTool(
                started,
                first.copy(
                    state = "completed",
                    result = "ok",
                    completedAt = Instant.EPOCH.plusSeconds(2),
                ),
            )
        val retained = partiallyComplete.single() as ChatItem.ParallelToolGroup
        assertEquals(listOf("completed", "running"), retained.tools.map { it.state })
    }

    @Test
    fun sequentialToolsAreNotGroupedAsParallel() {
        val first = ChatItem.Tool("1", "terminal", "completed", result = "ok")
        val second = ChatItem.Tool("2", "read_file", "running", arguments = "path")
        assertEquals(listOf(first, second), upsertTool(listOf(first), second))
    }

    @Test
    fun completedParallelGroupMovesIntoSummaryAtomicallyAndCountsChildren() {
        val parallel =
            ChatItem.ParallelToolGroup(
                "batch-1",
                listOf(
                    ChatItem.Tool("1", "terminal", "completed", result = "a"),
                    ChatItem.Tool("2", "terminal", "completed", result = "b"),
                ),
            )
        val items =
            listOf<ChatItem>(
                ChatItem.Tool("0", "read_file", "completed", result = "x"),
                parallel,
                ChatItem.Tool("3", "patch", "completed", result = "y"),
            )
        val summary = groupTimeline(items, minimumGroupSize = 4).single() as ChatItem.ToolGroup
        assertEquals(items, summary.operations)
        assertEquals(4, summary.callCount)
        assertEquals(3, summary.roundCount)
        assertEquals(
            linkedMapOf("read_file" to 1, "terminal" to 2, "patch" to 1),
            toolCountBreakdown(summary.operations),
        )
    }

    @Test
    fun activeParallelGroupNeverMovesIntoCompletedSummary() {
        val active =
            ChatItem.ParallelToolGroup(
                "batch-1",
                listOf(
                    ChatItem.Tool("1", "terminal", "completed", result = "a"),
                    ChatItem.Tool("2", "read_file", "running", arguments = "b"),
                ),
            )
        val blocks =
            groupTimeline(
                listOf(
                    ChatItem.Tool("a", "patch", "completed", result = ""),
                    ChatItem.Tool("b", "patch", "completed", result = ""),
                    ChatItem.Tool("c", "patch", "completed", result = ""),
                    ChatItem.Tool("d", "patch", "completed", result = ""),
                    active,
                )
            )
        assertTrue(blocks.first() is ChatItem.ToolGroup)
        assertEquals(active, blocks.last())
    }

    @Test
    fun insecurePublicHttpEndpointIsRejected() {
        assertTrue(ConnectionConfig("https://example.com").isAllowedEndpoint())
        assertTrue(ConnectionConfig("http://192.168.1.2:9119").isAllowedEndpoint())
        assertTrue(ConnectionConfig("http://100.90.1.2:9119").isAllowedEndpoint())
        assertTrue(ConnectionConfig("http://server.tail1234.ts.net:9119").isAllowedEndpoint())
        assertTrue(!ConnectionConfig("http://example.com").isAllowedEndpoint())
        assertTrue(!ConnectionConfig("https://user:pass@example.com").isAllowedEndpoint())
        assertTrue(!ConnectionConfig("https://example.com/hermes").isAllowedEndpoint())
        assertTrue(!ConnectionConfig("https://example.com?token=secret").isAllowedEndpoint())
    }

    @Test
    fun sessionActivityIsDecodedForLiveIndicators() {
        val session =
            HermesSession.fromJson(
                buildJsonObject {
                    put("id", "live")
                    put("title", "Live elsewhere")
                    put("active", true)
                }
            )
        assertTrue(session.active)
    }

    @Test
    fun modelCatalogDecodesConfiguredProvidersAndUnavailableModels() {
        val payload =
            Json.parseToJsonElement(
                    """{
                    "model":"gpt-5.6-sol",
                    "provider":"openai-codex",
                    "providers":[
                      {"slug":"openai-codex","name":"OpenAI Codex","authenticated":true,
                       "models":["gpt-5.6-sol","gpt-5.5"]},
                      {"slug":"nous","name":"Nous Portal","authenticated":true,
                       "models":["Hermes-4.3-36B"],"unavailable_models":["Hermes-4.3-36B"]},
                      {"slug":"anthropic","name":"Anthropic","authenticated":false,
                       "models":["claude-sonnet-4.6"]}
                    ]
                }"""
                )
                .jsonObject

        val catalog = ModelCatalog.fromJson(payload)

        assertEquals(ModelSelection("openai-codex", "gpt-5.6-sol"), catalog.selected)
        assertEquals(listOf("openai-codex", "nous"), catalog.providers.map { it.slug })
        assertTrue(catalog.providers[1].models.single().unavailable)
    }

    @Test
    fun modelCatalogFiltersModelsByProviderNameAndModelId() {
        val catalog =
            ModelCatalog(
                providers =
                    listOf(
                        dev.qelg.hermeschat.data.ModelProvider(
                            "anthropic",
                            "Anthropic",
                            listOf(dev.qelg.hermeschat.data.ModelOption("claude-sonnet-4.6")),
                        ),
                        dev.qelg.hermeschat.data.ModelProvider(
                            "openai-codex",
                            "OpenAI Codex",
                            listOf(dev.qelg.hermeschat.data.ModelOption("gpt-5.6-sol")),
                        ),
                    )
            )

        assertEquals(listOf("anthropic"), catalog.filtered("ANTHROPIC").map { it.slug })
        assertEquals(listOf("openai-codex"), catalog.filtered("5.6-sol").map { it.slug })
    }

    @Test
    fun modelSwitchIsExplicitlySessionScoped() {
        assertEquals(
            "gpt-5.6-sol --provider openai-codex --session",
            modelSwitchValue(ModelSelection("openai-codex", "gpt-5.6-sol")),
        )
    }

    @Test
    fun markdownLinksOnlyAllowExplicitSafeSchemes() {
        assertTrue(isSafeExternalUrl("https://example.com"))
        assertTrue(isSafeExternalUrl("mailto:person@example.com"))
        assertTrue(!isSafeExternalUrl("javascript:alert(1)"))
        assertTrue(!isSafeExternalUrl("intent://settings"))
        assertTrue(!isSafeExternalUrl("//example.com"))
    }
}
