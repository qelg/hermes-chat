@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package dev.qelg.hermeschat

import android.Manifest
import android.media.MediaRecorder
import android.os.Bundle
import android.text.method.LinkMovementMethod
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.text.HtmlCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.qelg.hermeschat.data.*
import org.commonmark.parser.Parser
import org.commonmark.renderer.html.HtmlRenderer
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) { HermesApp() } }
    }
}

@Composable
private fun HermesApp(vm: ChatViewModel = viewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()
    if (!state.configured) ConnectionScreen(vm::connect) else MainScreen(state, vm)
}

@Composable
private fun ConnectionScreen(connect: (ConnectionConfig) -> Unit) {
    var url by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var token by rememberSaveable { mutableStateOf("") }
    Surface(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxWidth().widthIn(max = 520.dp).padding(24.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Spacer(Modifier.height(40.dp)); Text("Connect to Hermes", style = MaterialTheme.typography.headlineMedium)
            Text("Uses the authenticated Hermes Desktop server at /api/ws.")
            OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text("Server URL") }, placeholder = { Text("https://hermes.example") }, singleLine = true)
            OutlinedTextField(token, { token = it }, Modifier.fillMaxWidth(), label = { Text("Session token (optional)") }, singleLine = true)
            HorizontalDivider(); Text("Or sign in with password", style = MaterialTheme.typography.labelLarge)
            OutlinedTextField(username, { username = it }, Modifier.fillMaxWidth(), label = { Text("Username") }, singleLine = true)
            OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth(), label = { Text("Password") }, singleLine = true, visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation())
            Button({ connect(ConnectionConfig(url, username, password, token)) }, enabled = url.isNotBlank() && (token.isNotBlank() || (username.isNotBlank() && password.isNotBlank())), modifier = Modifier.fillMaxWidth()) { Text("Connect") }
            Text("Credentials are encrypted with Android Keystore.", style = MaterialTheme.typography.bodySmall)
        }
    }
}

@Composable
private fun MainScreen(state: ChatUiState, vm: ChatViewModel) {
    var showSessions by rememberSaveable { mutableStateOf(state.selectedId == null) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 760.dp
        if (wide) Row { SessionPane(state, vm, Modifier.width(320.dp).fillMaxHeight()) { }; VerticalDivider(); ChatPane(state, vm, Modifier.weight(1f)) }
        else if (showSessions || state.selectedId == null) SessionPane(state, vm, Modifier.fillMaxSize()) { showSessions = false }
        else ChatPane(state, vm, Modifier.fillMaxSize(), onBack = { showSessions = true })
    }
    state.approval?.let { approval ->
        AlertDialog(
            onDismissRequest = {},
            icon = { Icon(Icons.Default.Warning, null) },
            title = { Text("Approval required") },
            text = { Column { Text(approval.description); if (approval.command.isNotBlank()) SelectionContainer { Text(approval.command, style = MaterialTheme.typography.bodySmall) } } },
            confirmButton = { Row { TextButton({ vm.approve("allow_once") }) { Text("Allow once") }; if (approval.allowPermanent) TextButton({ vm.approve("allow_always") }) { Text("Always") } } },
            dismissButton = { TextButton({ vm.approve("deny") }) { Text("Deny") } },
        )
    }
}

@Composable
private fun SessionPane(state: ChatUiState, vm: ChatViewModel, modifier: Modifier, selected: () -> Unit) {
    val sessions = remember(state.sessions, state.search) { filterSessions(state.sessions, state.search) }
    Column(modifier) {
        TopAppBar(title = { Text("Sessions") }, actions = {
            IconButton(vm::refresh) { Icon(Icons.Default.Refresh, "Refresh") }
            IconButton(vm::disconnect) { Icon(Icons.Default.Logout, "Disconnect") }
        })
        OutlinedTextField(state.search, vm::setSearch, Modifier.fillMaxWidth().padding(horizontal = 12.dp), leadingIcon = { Icon(Icons.Default.Search, null) }, placeholder = { Text("Search") }, singleLine = true)
        Button({ vm.createSession(); selected() }, Modifier.fillMaxWidth().padding(12.dp)) { Icon(Icons.Default.Add, null); Spacer(Modifier.width(8.dp)); Text("New session") }
        if (state.connecting) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(Modifier.weight(1f)) {
            items(sessions, key = { it.id }) { session ->
                ListItem(
                    headlineContent = { Text(session.title, maxLines = 1) },
                    supportingContent = { session.preview?.let { Text(it, maxLines = 2) } },
                    leadingContent = { Icon(if (session.id == state.selectedId) Icons.Default.Chat else Icons.Default.History, null) },
                    modifier = Modifier.clickable { vm.select(session); selected() },
                    colors = ListItemDefaults.colors(containerColor = if (session.id == state.selectedId) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent),
                )
            }
        }
    }
}

@Composable
private fun ChatPane(state: ChatUiState, vm: ChatViewModel, modifier: Modifier, onBack: (() -> Unit)? = null) {
    var input by rememberSaveable { mutableStateOf("") }
    val blocks = remember(state.items) { groupTimeline(state.items) }
    val list = rememberLazyListState()
    LaunchedEffect(blocks.size, (blocks.lastOrNull() as? ChatItem.Message)?.text) { if (blocks.isNotEmpty()) list.animateScrollToItem(blocks.lastIndex) }
    Column(modifier) {
        TopAppBar(
            navigationIcon = { onBack?.let { IconButton(it) { Icon(Icons.Default.ArrowBack, "Sessions") } } },
            title = { Text(state.title, maxLines = 1) },
            actions = { if (state.active) IconButton(vm::interrupt) { Icon(Icons.Default.Stop, "Stop") } },
        )
        state.error?.let { Surface(color = MaterialTheme.colorScheme.errorContainer) { Text(it.text, Modifier.fillMaxWidth().padding(10.dp), color = MaterialTheme.colorScheme.onErrorContainer) } }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            itemsIndexed(blocks) { _, item -> TimelineItem(item) }
            if (state.active) item { Row(verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)); Text("Hermes is working…") } }
        }
        HorizontalDivider()
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.Bottom) {
            VoiceButton(vm) { input = if (input.isBlank()) it else "$input\n$it" }
            OutlinedTextField(input, { input = it }, Modifier.weight(1f), placeholder = { Text("Message Hermes") }, maxLines = 6)
            IconButton({ val text = input; input = ""; vm.send(text) }, enabled = input.isNotBlank() && !state.connecting) { Icon(Icons.Default.Send, "Send") }
        }
    }
}

@Composable
private fun TimelineItem(item: ChatItem) {
    when (item) {
        is ChatItem.Message -> Row(Modifier.fillMaxWidth(), horizontalArrangement = if (item.role == "user") Arrangement.End else Arrangement.Start) {
            Surface(color = if (item.role == "user") MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant, shape = RoundedCornerShape(16.dp), modifier = Modifier.widthIn(max = 680.dp)) {
                if (item.role == "assistant") MarkdownText(item.text, Modifier.padding(12.dp)) else SelectionContainer { Text(item.text, Modifier.padding(12.dp)) }
            }
        }
        is ChatItem.Tool -> ToolCard(item)
        is ChatItem.ToolGroup -> { var expanded by rememberSaveable { mutableStateOf(false) }; Card(Modifier.fillMaxWidth().clickable { expanded = !expanded }) { Column(Modifier.padding(12.dp)) { Row(verticalAlignment = Alignment.CenterVertically) { Icon(Icons.Default.Build, null); Spacer(Modifier.width(8.dp)); Text("${item.tools.size} tool calls", Modifier.weight(1f)); Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null) }; if (expanded) item.tools.forEach { ToolCard(it) } } } }
        is ChatItem.Status -> Text(item.text, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun ToolCard(tool: ChatItem.Tool) {
    var expanded by rememberSaveable(tool.id, tool.state) { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text("${tool.name} · ${tool.state}${tool.durationMs?.let { " · %.1f s".format(it / 1000.0) }.orEmpty()}") },
        leadingContent = { Icon(toolIcon(tool.name), null) },
        trailingContent = { Icon(if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore, null) },
        supportingContent = { if (expanded) SelectionContainer { Text(tool.details, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace) } },
        modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded },
    )
}

private fun toolIcon(name: String) = when {
    name.contains("file", true) || name.contains("read", true) || name.contains("write", true) -> Icons.Default.Description
    name.contains("web", true) || name.contains("search", true) -> Icons.Default.Language
    name.contains("image", true) || name.contains("media", true) -> Icons.Default.Image
    name.contains("git", true) -> Icons.Default.Source
    else -> Icons.Default.Terminal
}

@Composable
private fun MarkdownText(markdown: String, modifier: Modifier = Modifier) {
    val html = remember(markdown) { HtmlRenderer.builder().escapeHtml(true).build().render(Parser.builder().build().parse(markdown)) }
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    AndroidView(
        factory = { context -> TextView(context).apply { movementMethod = LinkMovementMethod.getInstance(); setTextIsSelectable(true) } },
        update = { it.text = HtmlCompat.fromHtml(html, HtmlCompat.FROM_HTML_MODE_COMPACT); it.setTextColor(android.graphics.Color.argb((color.alpha * 255).toInt(), (color.red * 255).toInt(), (color.green * 255).toInt(), (color.blue * 255).toInt())) },
        modifier = modifier,
    )
}

@Composable
private fun VoiceButton(vm: ChatViewModel, onText: (String) -> Unit) {
    val context = LocalContext.current
    var recorder by remember { mutableStateOf<MediaRecorder?>(null) }
    var file by remember { mutableStateOf<File?>(null) }
    fun start() {
        val output = File.createTempFile("hermes-voice-", ".m4a", context.cacheDir)
        @Suppress("DEPRECATION") val next = MediaRecorder().apply {
            setAudioSource(MediaRecorder.AudioSource.MIC); setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC); setOutputFile(output.absolutePath); prepare(); start()
        }
        file = output; recorder = next
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) start() }
    IconButton({
        val active = recorder
        if (active == null) permission.launch(Manifest.permission.RECORD_AUDIO)
        else {
            runCatching { active.stop() }; active.release(); recorder = null
            file?.let { audio -> vm.transcribe(audio.readBytes(), "audio/mp4") { onText(it); audio.delete() } }
        }
    }) { Icon(if (recorder == null) Icons.Default.Mic else Icons.Default.Stop, if (recorder == null) "Record voice" else "Stop recording", tint = if (recorder == null) LocalContentColor.current else MaterialTheme.colorScheme.error) }
    DisposableEffect(Unit) { onDispose { recorder?.release() } }
}
