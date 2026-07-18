@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package dev.qelg.hermeschat

import android.Manifest
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.text.SpannableString
import android.text.method.LinkMovementMethod
import android.text.style.URLSpan
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.text.HtmlCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.qelg.hermeschat.data.*
import java.io.File
import org.commonmark.ext.gfm.tables.TablesExtension
import org.commonmark.parser.Parser
import org.commonmark.renderer.html.HtmlRenderer

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(
                colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()
            ) {
                HermesApp()
            }
        }
    }
}

@Composable
private fun HermesApp(vm: ChatViewModel = viewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    Box(
        Modifier.fillMaxSize()
            .windowInsetsPadding(contentInsets(WindowInsets.safeDrawing, WindowInsets.ime))
    ) {
        if (!state.configured) ConnectionScreen(vm::connect) else MainScreen(state, vm)
    }
}

internal fun contentInsets(safeDrawing: WindowInsets, ime: WindowInsets): WindowInsets =
    safeDrawing.union(ime)

@Composable
private fun ConnectionScreen(connect: (ConnectionConfig) -> Unit) {
    var url by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var token by rememberSaveable { mutableStateOf("") }
    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxWidth()
                .widthIn(max = 520.dp)
                .padding(24.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Spacer(Modifier.height(40.dp))
            Text("Connect to Hermes", style = MaterialTheme.typography.headlineMedium)
            Text("Uses the authenticated Hermes Desktop server at /api/ws.")
            OutlinedTextField(
                url,
                { url = it },
                Modifier.fillMaxWidth(),
                label = { Text("Server URL") },
                placeholder = { Text("https://hermes.example") },
                singleLine = true,
            )
            OutlinedTextField(
                token,
                { token = it },
                Modifier.fillMaxWidth(),
                label = { Text("Session token (optional)") },
                singleLine = true,
            )
            HorizontalDivider()
            Text("Or sign in with password", style = MaterialTheme.typography.labelLarge)
            OutlinedTextField(
                username,
                { username = it },
                Modifier.fillMaxWidth(),
                label = { Text("Username") },
                singleLine = true,
            )
            OutlinedTextField(
                password,
                { password = it },
                Modifier.fillMaxWidth(),
                label = { Text("Password") },
                singleLine = true,
                visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
            )
            Button(
                { connect(ConnectionConfig(url, username, password, token)) },
                enabled =
                    url.isNotBlank() &&
                        (token.isNotBlank() || (username.isNotBlank() && password.isNotBlank())),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Connect")
            }
            Text(
                "Credentials are encrypted with Android Keystore.",
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun MainScreen(state: ChatUiState, vm: ChatViewModel) {
    var showSessions by rememberSaveable { mutableStateOf(state.selectedId == null) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 760.dp
        if (wide)
            Row {
                SessionPane(state, vm, Modifier.width(320.dp).fillMaxHeight()) {}
                VerticalDivider()
                ChatPane(state, vm, Modifier.weight(1f))
            }
        else if (showSessions || state.selectedId == null)
            SessionPane(state, vm, Modifier.fillMaxSize()) { showSessions = false }
        else ChatPane(state, vm, Modifier.fillMaxSize(), onBack = { showSessions = true })
    }
    state.approval?.let { approval ->
        AlertDialog(
            onDismissRequest = {},
            icon = { Icon(Icons.Default.Warning, null) },
            title = { Text("Approval required") },
            text = {
                Column {
                    Text(approval.description)
                    if (approval.command.isNotBlank())
                        SelectionContainer {
                            Text(approval.command, style = MaterialTheme.typography.bodySmall)
                        }
                }
            },
            confirmButton = {
                Row {
                    TextButton({ vm.approve("once") }) { Text("Allow once") }
                    if (approval.allowPermanent)
                        TextButton({ vm.approve("always") }) { Text("Always") }
                }
            },
            dismissButton = { TextButton({ vm.approve("deny") }) { Text("Deny") } },
        )
    }
    UpdateDialog(state.updateState, vm::downloadUpdate, vm::resetUpdateState)
}

@Composable
private fun SessionPane(
    state: ChatUiState,
    vm: ChatViewModel,
    modifier: Modifier,
    selected: () -> Unit,
) {
    val sessions =
        remember(state.sessions, state.search) { filterSessions(state.sessions, state.search) }
    Column(modifier) {
        TopAppBar(
            title = { Text("Sessions") },
            windowInsets = WindowInsets(0, 0, 0, 0),
            actions = {
                IconButton(vm::refresh) { Icon(Icons.Default.Refresh, "Refresh") }
                IconButton(vm::checkForUpdate) {
                    Icon(Icons.Default.SystemUpdate, "Check for updates")
                }
                IconButton(vm::disconnect) { Icon(Icons.AutoMirrored.Filled.Logout, "Disconnect") }
            },
        )
        OutlinedTextField(
            state.search,
            vm::setSearch,
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            leadingIcon = { Icon(Icons.Default.Search, null) },
            placeholder = { Text("Search") },
            singleLine = true,
        )
        Button(
            {
                vm.createSession()
                selected()
            },
            Modifier.fillMaxWidth().padding(12.dp),
        ) {
            Icon(Icons.Default.Add, null)
            Spacer(Modifier.width(8.dp))
            Text("New session")
        }
        if (state.connecting) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(Modifier.weight(1f)) {
            items(sessions, key = { it.id }) { session ->
                ListItem(
                    headlineContent = { Text(session.title, maxLines = 1) },
                    supportingContent = { session.preview?.let { Text(it, maxLines = 2) } },
                    leadingContent = {
                        if (session.active) Badge { Text("LIVE") }
                        else
                            Icon(
                                if (session.id == state.selectedId) Icons.AutoMirrored.Filled.Chat
                                else Icons.Default.History,
                                null,
                            )
                    },
                    modifier =
                        Modifier.clickable {
                            vm.select(session)
                            selected()
                        },
                    colors =
                        ListItemDefaults.colors(
                            containerColor =
                                if (session.id == state.selectedId)
                                    MaterialTheme.colorScheme.secondaryContainer
                                else Color.Transparent
                        ),
                )
            }
        }
    }
}

@Composable
private fun ChatPane(
    state: ChatUiState,
    vm: ChatViewModel,
    modifier: Modifier,
    onBack: (() -> Unit)? = null,
) {
    var input by rememberSaveable { mutableStateOf("") }
    var showModels by rememberSaveable { mutableStateOf(false) }
    val blocks = remember(state.items) { groupTimeline(state.items) }
    val list = rememberLazyListState()
    LaunchedEffect(blocks.size, (blocks.lastOrNull() as? ChatItem.Message)?.text) {
        if (blocks.isNotEmpty()) list.animateScrollToItem(blocks.lastIndex)
    }
    Column(modifier) {
        TopAppBar(
            navigationIcon = {
                onBack?.let {
                    IconButton(it) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Sessions") }
                }
            },
            title = {
                Column {
                    Text(state.title, maxLines = 1)
                    state.modelCatalog.selected?.let {
                        Text(
                            it.model,
                            maxLines = 1,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            },
            windowInsets = WindowInsets(0, 0, 0, 0),
            actions = {
                IconButton(
                    {
                        showModels = true
                        vm.refreshModels()
                    },
                    enabled = !state.active,
                ) {
                    Icon(Icons.Default.SmartToy, "Choose model")
                }
                if (state.active) IconButton(vm::interrupt) { Icon(Icons.Default.Stop, "Stop") }
            },
        )
        state.error?.let { error ->
            Surface(
                color = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer,
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(error.text)
                        state.reconnectSeconds?.let { seconds ->
                            Text(
                                "Next connection attempt in $seconds s",
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                    }
                    state.reconnectSeconds?.let {
                        Spacer(Modifier.width(8.dp))
                        Button(onClick = vm::reconnectNow) { Text("Connect now") }
                    }
                }
            }
        }
        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(),
            state = list,
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            itemsIndexed(blocks) { _, item -> TimelineItem(item) }
            if (state.active)
                item {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Hermes is working…")
                    }
                }
        }
        HorizontalDivider()
        if (state.transcribing) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
                Text("Uploading and transcribing voice…")
            }
        }
        state.clarify?.let { clarify ->
            Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.AutoMirrored.Filled.Help,
                        null,
                        tint = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        clarify.question,
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
                if (clarify.choices.isNotEmpty()) {
                    Spacer(Modifier.height(6.dp))
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        clarify.choices.forEach { choice ->
                            AssistChip(
                                onClick = { vm.answerClarify(choice) },
                                label = { Text(choice) },
                            )
                        }
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.Bottom) {
            VoiceButton(vm, enabled = !state.transcribing) { text -> vm.send(text) }
            OutlinedTextField(
                input,
                { input = it },
                Modifier.weight(1f),
                placeholder = {
                    Text(state.clarify?.question?.takeIf(String::isNotBlank) ?: "Message Hermes")
                },
                maxLines = 6,
            )
            IconButton(
                {
                    val text = input
                    input = ""
                    if (state.clarify != null) vm.answerClarify(text) else vm.send(text)
                },
                enabled = input.isNotBlank() && !state.connecting,
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, "Send")
            }
        }
    }
    if (showModels) {
        ModelPickerDialog(
            catalog = state.modelCatalog,
            loading = state.modelLoading,
            onRefresh = vm::refreshModels,
            onSelect = {
                vm.selectModel(it)
                showModels = false
            },
            onDismiss = { showModels = false },
        )
    }
}

@Composable
private fun ModelPickerDialog(
    catalog: ModelCatalog,
    loading: Boolean,
    onRefresh: () -> Unit,
    onSelect: (ModelSelection) -> Unit,
    onDismiss: () -> Unit,
) {
    var search by rememberSaveable { mutableStateOf("") }
    val providers = remember(catalog, search) { catalog.filtered(search) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Choose model", Modifier.weight(1f))
                IconButton(onRefresh, enabled = !loading) {
                    Icon(Icons.Default.Refresh, "Refresh models")
                }
            }
        },
        text = {
            Column(Modifier.fillMaxWidth()) {
                OutlinedTextField(
                    search,
                    { search = it },
                    Modifier.fillMaxWidth(),
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    placeholder = { Text("Search providers and models") },
                    singleLine = true,
                )
                Spacer(Modifier.height(8.dp))
                if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (!loading && providers.isEmpty()) {
                    Text(
                        "No configured models found.",
                        Modifier.padding(vertical = 24.dp),
                        style = MaterialTheme.typography.bodyMedium,
                    )
                } else {
                    LazyColumn(Modifier.fillMaxWidth().heightIn(max = 480.dp)) {
                        providers.forEach { provider ->
                            item(key = "provider-${provider.slug}") {
                                Text(
                                    provider.name,
                                    Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 4.dp),
                                    style = MaterialTheme.typography.titleSmall,
                                )
                            }
                            items(provider.models, key = { "${provider.slug}/${it.id}" }) { model ->
                                val selection = ModelSelection(provider.slug, model.id)
                                val selected = selection == catalog.selected
                                ListItem(
                                    headlineContent = { Text(model.id) },
                                    supportingContent = {
                                        if (model.unavailable) Text("Unavailable for this account")
                                    },
                                    leadingContent = {
                                        RadioButton(
                                            selected = selected,
                                            onClick = null,
                                            enabled = !model.unavailable && !loading,
                                        )
                                    },
                                    modifier =
                                        Modifier.clickable(
                                            enabled = !model.unavailable && !loading && !selected
                                        ) {
                                            onSelect(selection)
                                        },
                                    colors =
                                        ListItemDefaults.colors(
                                            containerColor =
                                                if (selected)
                                                    MaterialTheme.colorScheme.secondaryContainer
                                                else Color.Transparent
                                        ),
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onDismiss) { Text("Close") } },
    )
}

@Composable
private fun TimelineItem(item: ChatItem) {
    when (item) {
        is ChatItem.Message -> MessageCard(item)
        is ChatItem.Tool -> ToolCard(item)
        is ChatItem.ParallelToolGroup -> ParallelToolGroupCard(item)
        is ChatItem.ToolGroup -> ToolSummaryCard(item)
        is ChatItem.Status ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(item.text, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                item.timestamp?.let { ClockText(it) }
            }
    }
}

@Composable
private fun MessageCard(message: ChatItem.Message) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (message.role == "user") Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            color =
                if (message.role == "user") MaterialTheme.colorScheme.primaryContainer
                else MaterialTheme.colorScheme.surfaceVariant,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.widthIn(max = 680.dp),
        ) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                if (message.role == "assistant") MarkdownText(message.text)
                else SelectionContainer { Text(message.text) }
                message.timestamp?.let {
                    ClockText(it, Modifier.align(Alignment.End).padding(top = 2.dp))
                }
            }
        }
    }
}

@Composable
private fun ToolSummaryCard(group: ChatItem.ToolGroup) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val breakdown = remember(group.operations) { toolCountBreakdown(group.operations) }
    Card(Modifier.fillMaxWidth().clickable { expanded = !expanded }) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Build, null)
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text("${group.callCount} tool calls")
                    Text(
                        breakdown.entries.joinToString(" · ") { "${it.key} ×${it.value}" },
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                    )
                }
                Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null)
            }
            if (expanded)
                group.operations.forEach { operation ->
                    when (operation) {
                        is ChatItem.Tool -> ToolCard(operation)
                        is ChatItem.ParallelToolGroup -> ParallelToolGroupCard(operation)
                        else -> Unit
                    }
                }
        }
    }
}

@Composable
private fun ParallelToolGroupCard(group: ChatItem.ParallelToolGroup) {
    var expanded by rememberSaveable(group.id) { mutableStateOf(true) }
    val complete = group.final
    val totalMs =
        if (complete && group.tools.all { it.durationMs != null }) {
            val first = group.tools.mapNotNull { it.startedAt }.minOrNull()
            val last = group.tools.mapNotNull { it.completedAt }.maxOrNull()
            if (first != null && last != null)
                java.time.Duration.between(first, last).toMillis().takeIf { it >= 0 }
            else null
        } else null
    Card(
        Modifier.fillMaxWidth().clickable { expanded = !expanded },
        colors =
            CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
    ) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.AccountTree, null, Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Parallel · ${group.tools.size} calls", Modifier.weight(1f))
                totalMs?.let {
                    Text(formatElapsed(it), style = MaterialTheme.typography.labelSmall)
                }
                Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null)
            }
            if (expanded) group.tools.forEach { ToolCard(it, nested = true) }
        }
    }
}

@Composable
private fun ToolCard(tool: ChatItem.Tool, nested: Boolean = false) {
    var expanded by rememberSaveable(tool.id) { mutableStateOf(false) }
    var now by remember(tool.id, tool.startedAt) { mutableStateOf(java.time.Instant.now()) }
    LaunchedEffect(tool.id, tool.state, tool.startedAt) {
        while (!tool.final && tool.startedAt != null) {
            now = java.time.Instant.now()
            kotlinx.coroutines.delay(250)
        }
    }
    val durationMs =
        tool.durationMs
            ?: if (!tool.final && tool.startedAt != null)
                java.time.Duration.between(tool.startedAt, now).toMillis().coerceAtLeast(0)
            else null
    ListItem(
        headlineContent = {
            Text(
                buildString {
                    append(tool.name)
                    append(" · ")
                    append(tool.state)
                    durationMs?.let {
                        append(" · ")
                        if (tool.durationEstimated) append("≈ ")
                        append(formatElapsed(it))
                    }
                }
            )
        },
        leadingContent = { Icon(toolIcon(tool.name), null) },
        trailingContent = {
            Column(horizontalAlignment = Alignment.End) {
                (tool.startedAt ?: tool.completedAt)?.let { ClockText(it) }
                if (tool.details.isNotBlank())
                    Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null)
            }
        },
        supportingContent = {
            if (expanded && tool.details.isNotBlank())
                SelectionContainer {
                    Text(
                        tool.details,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    )
                }
        },
        colors =
            ListItemDefaults.colors(
                containerColor =
                    if (nested) MaterialTheme.colorScheme.surfaceContainerHigh
                    else Color.Transparent
            ),
        modifier =
            Modifier.fillMaxWidth()
                .then(
                    if (tool.details.isNotBlank()) Modifier.clickable { expanded = !expanded }
                    else Modifier
                ),
    )
}

private fun formatElapsed(durationMs: Long): String = "%.1f s".format(durationMs / 1000.0)

@Composable
private fun ClockText(timestamp: java.time.Instant, modifier: Modifier = Modifier) {
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    val locale =
        remember(configuration) {
            configuration.locales.get(0)?.let {
                java.util.Locale.forLanguageTag(it.toLanguageTag())
            } ?: java.util.Locale.getDefault()
        }
    Text(
        formatClockTime(timestamp, locale = locale),
        modifier = modifier,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
    )
}

private fun toolIcon(name: String) =
    when {
        name.contains("file", true) ||
            name.contains("read", true) ||
            name.contains("write", true) -> Icons.Default.Description
        name.contains("web", true) || name.contains("search", true) -> Icons.Default.Language
        name.contains("image", true) || name.contains("media", true) -> Icons.Default.Image
        name.contains("git", true) -> Icons.Default.Source
        else -> Icons.Default.Terminal
    }

@Composable
private fun MarkdownText(markdown: String, modifier: Modifier = Modifier) {
    val html =
        remember(markdown) {
            val parser = Parser.builder().extensions(listOf(TablesExtension.create())).build()
            val raw = HtmlRenderer.builder().escapeHtml(true).build().render(parser.parse(markdown))
            replaceTablesWithText(raw)
        }
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    AndroidView(
        factory = { context ->
            TextView(context).apply {
                movementMethod = LinkMovementMethod.getInstance()
                setTextIsSelectable(true)
            }
        },
        update = {
            val safe = SpannableString(HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_COMPACT))
            safe.getSpans(0, safe.length, URLSpan::class.java).forEach { span ->
                if (!isSafeExternalUrl(span.url)) safe.removeSpan(span)
            }
            it.text = safe
            it.setTextColor(
                android.graphics.Color.argb(
                    (color.alpha * 255).toInt(),
                    (color.red * 255).toInt(),
                    (color.green * 255).toInt(),
                    (color.blue * 255).toInt(),
                )
            )
        },
        modifier = modifier,
    )
}

private fun replaceTablesWithText(html: String): String {
    val tablePattern = Regex("<table>(.*?)</table>", RegexOption.DOT_MATCHES_ALL)
    return tablePattern.replace(html) { match ->
        val body = match.groupValues[1]
        val rows =
            Regex("<tr>(.*?)</tr>", RegexOption.DOT_MATCHES_ALL)
                .findAll(body)
                .map { rowMatch ->
                    Regex("<t[hd]>(.*?)</t[hd]>", RegexOption.DOT_MATCHES_ALL)
                        .findAll(rowMatch.groupValues[1])
                        .map { it.groupValues[1].replace(Regex("<[^>]+>"), "").trim() }
                        .toList()
                }
                .toList()
        if (rows.isEmpty() || rows.all { it.isEmpty() }) return@replace ""
        val colCount = rows.maxOf { it.size }
        val colWidths =
            (0 until colCount).map { col -> rows.maxOf { row -> row.getOrElse(col) { "" }.length } }
        val lines =
            rows.map { row ->
                (0 until colCount).joinToString(" | ") { col ->
                    row.getOrElse(col) { "" }.padEnd(colWidths[col])
                }
            }
        "<pre>" + lines.joinToString("\n") + "</pre>"
    }
}

@Composable
private fun VoiceButton(vm: ChatViewModel, enabled: Boolean, onText: (String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var recorder by remember { mutableStateOf<MediaRecorder?>(null) }
    var file by remember { mutableStateOf<File?>(null) }
    fun discardRecording() {
        val active = recorder
        recorder = null
        runCatching { active?.stop() }
        runCatching { active?.release() }
        file?.delete()
        file = null
    }
    fun start() {
        val output = File.createTempFile("hermes-voice-", ".m4a", context.cacheDir)
        @Suppress("DEPRECATION")
        val next =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context)
            else MediaRecorder()
        runCatching {
                next.setAudioSource(MediaRecorder.AudioSource.MIC)
                next.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                next.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                next.setOutputFile(output.absolutePath)
                next.prepare()
                next.start()
                file = output
                recorder = next
            }
            .onFailure {
                runCatching { next.release() }
                output.delete()
                vm.reportError(IllegalStateException("Could not start voice recording", it))
            }
    }
    val permission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
            if (it) start()
        }
    IconButton(
        onClick = {
            val active = recorder
            if (active == null) permission.launch(Manifest.permission.RECORD_AUDIO)
            else {
                recorder = null
                val audio = file
                file = null
                val stopped = runCatching { active.stop() }.isSuccess
                runCatching { active.release() }
                if (!stopped || audio == null || audio.length() == 0L) {
                    audio?.delete()
                    vm.reportError(
                        IllegalStateException("Voice recording failed; nothing was uploaded")
                    )
                } else {
                    val bytes =
                        runCatching { audio.readBytes() }
                            .getOrElse {
                                audio.delete()
                                vm.reportError(it)
                                return@IconButton
                            }
                    vm.transcribe(bytes, "audio/mp4", { it.onSuccess(onText) }, { audio.delete() })
                }
            }
        },
        enabled = enabled,
    ) {
        Icon(
            if (recorder == null) Icons.Default.Mic else Icons.Default.Stop,
            if (recorder == null) "Record voice" else "Stop recording",
            tint =
                if (recorder == null) LocalContentColor.current else MaterialTheme.colorScheme.error,
        )
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) discardRecording()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            discardRecording()
        }
    }
}

@Composable
private fun UpdateDialog(updateState: UpdateState, onDownload: () -> Unit, onDismiss: () -> Unit) {
    if (
        !updateState.checking &&
            !updateState.available &&
            !updateState.upToDate &&
            !updateState.downloading &&
            updateState.error == null
    )
        return
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = {
            when {
                updateState.checking || updateState.downloading ->
                    CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                updateState.available -> Icon(Icons.Default.SystemUpdate, null)
                updateState.upToDate -> Icon(Icons.Default.CheckCircle, null)
                else -> Icon(Icons.Default.Error, null)
            }
        },
        title = {
            Text(
                when {
                    updateState.checking -> "Checking for updates…"
                    updateState.downloading -> "Downloading update…"
                    updateState.available -> "Update available"
                    updateState.upToDate -> "Up to date"
                    updateState.error != null -> "Update check failed"
                    else -> "Update"
                }
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when {
                    updateState.checking -> Text("Connecting to GitHub…")
                    updateState.downloading -> {
                        Text("Downloading Hermes Chat ${updateState.latestVersion ?: ""}")
                        Spacer(Modifier.height(4.dp))
                        LinearProgressIndicator(
                            progress = { updateState.downloadProgress },
                            Modifier.fillMaxWidth(),
                        )
                        Text(
                            "${(updateState.downloadProgress * 100).toInt()}%",
                            Modifier.align(Alignment.CenterHorizontally),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                    updateState.available ->
                        Text(
                            "A new version is available: ${updateState.latestVersion ?: "latest"} (versionCode ${updateState.latestVersionCode ?: "?"}).\n\nYour version: ${updateState.currentVersion}\n\nDownload and install?"
                        )
                    updateState.upToDate ->
                        Text(
                            "You have the latest version: ${updateState.currentVersion} (versionCode ${updateState.latestVersionCode ?: "?"})."
                        )
                    updateState.error != null -> Text(updateState.error ?: "Unknown error")
                }
            }
        },
        confirmButton = {
            when {
                updateState.available -> Button(onDownload) { Text("Download & Install") }
                updateState.downloading -> {}
                else -> TextButton(onDismiss) { Text("Close") }
            }
        },
        dismissButton = {
            if (updateState.available || updateState.error != null)
                TextButton(onDismiss) { Text("Cancel") }
        },
    )
}
