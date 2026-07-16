import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'api/hermes_api.dart';
import 'chat_controller.dart';
import 'connection.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets/tool_event_tile.dart';

class HermesChatApp extends StatefulWidget {
  const HermesChatApp({super.key});

  @override
  State<HermesChatApp> createState() => _HermesChatAppState();
}

class _HermesChatAppState extends State<HermesChatApp> {
  final _store = ConnectionStore();
  ChatController? _controller;
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final config = await _store.load();
      if (config != null) await _connect(config);
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<String?> _connect(
    ConnectionConfig config, {
    bool verify = true,
  }) async {
    final validationError = config.validationError;
    if (validationError != null) return validationError;
    final api = HermesApi(config);
    try {
      if (verify) await api.checkHealth();
      await _store.save(config);
      final controller = ChatController(api);
      await controller.loadSessions();
      _controller?.dispose();
      if (mounted) setState(() => _controller = controller);
      return null;
    } catch (error) {
      api.close();
      return error.toString();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hermes Chat',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: _initializing
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _controller == null
          ? ConnectionScreen(onConnect: _connect)
          : ChatShell(
              controller: _controller!,
              onSettings: () => _showSettings(context),
            ),
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    final result = await showDialog<ConnectionConfig>(
      context: context,
      builder: (_) => const ConnectionDialog(),
    );
    if (result != null) await _connect(result);
  }
}

class ConnectionScreen extends StatelessWidget {
  const ConnectionScreen({super.key, required this.onConnect});
  final Future<String?> Function(ConnectionConfig) onConnect;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.auto_awesome_rounded,
                  size: 42,
                  color: Color(0xFF828FFF),
                ),
                const SizedBox(height: 20),
                Text(
                  'Your direct line to Hermes',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  'Connect to the same private Hermes backend as Hermes Desktop. Sessions, tools, voice, and approvals stay native to Hermes.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: () async {
                    final config = await showDialog<ConnectionConfig>(
                      context: context,
                      builder: (_) => const ConnectionDialog(),
                    );
                    if (config != null) {
                      final error = await onConnect(config);
                      if (context.mounted && error != null) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(error)));
                      }
                    }
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Connect Hermes'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({super.key});

  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Hermes connection'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://hermes.example.ts.net',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _username,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_url.text.trim().isEmpty ||
                _username.text.trim().isEmpty ||
                _password.text.isEmpty) {
              return;
            }
            Navigator.pop(
              context,
              ConnectionConfig(
                baseUrl: _url.text,
                username: _username.text,
                password: _password.text,
              ),
            );
          },
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

class ChatShell extends StatefulWidget {
  const ChatShell({
    super.key,
    required this.controller,
    required this.onSettings,
  });
  final ChatController controller;
  final VoidCallback onSettings;

  @override
  State<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends State<ChatShell> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant ChatShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final sidebar = SessionSidebar(
      controller: widget.controller,
      onSelected: (session) async {
        await widget.controller.select(session);
        if (!wide && context.mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MobileChatPage(controller: widget.controller),
            ),
          );
        }
      },
      onCreated: (_) {
        if (!wide && context.mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MobileChatPage(controller: widget.controller),
            ),
          );
        }
      },
      onSettings: widget.onSettings,
    );
    if (!wide) return Scaffold(body: sidebar);
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 310, child: sidebar),
          const VerticalDivider(width: 1),
          Expanded(child: ChatPane(controller: widget.controller)),
        ],
      ),
    );
  }
}

class SessionSidebar extends StatefulWidget {
  const SessionSidebar({
    super.key,
    required this.controller,
    required this.onSelected,
    this.onCreated,
    required this.onSettings,
  });
  final ChatController controller;
  final ValueChanged<HermesSession> onSelected;
  final ValueChanged<HermesSession>? onCreated;
  final VoidCallback onSettings;

  @override
  State<SessionSidebar> createState() => _SessionSidebarState();
}

class _SessionSidebarState extends State<SessionSidebar> {
  bool _searching = false;
  String _query = '';

  ChatController get controller => widget.controller;
  ValueChanged<HermesSession> get onSelected => widget.onSelected;
  VoidCallback get onSettings => widget.onSettings;

  @override
  Widget build(BuildContext context) {
    final visibleSessions = filterSessions(controller.sessions, _query);
    return Material(
      color: const Color(0xFF0F1011),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 10, 12),
              child: Row(
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    color: Color(0xFF828FFF),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Hermes',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _searching ? 'Close search' : 'Search sessions',
                    onPressed: () => setState(() {
                      _searching = !_searching;
                      if (!_searching) _query = '';
                    }),
                    icon: Icon(_searching ? Icons.close : Icons.search),
                  ),
                  IconButton(
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: TextField(
                  autofocus: true,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: 'Search sessions…',
                    prefixIcon: Icon(Icons.search, size: 19),
                    isDense: true,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: () async {
                  final session = await controller.createSession();
                  if (session != null) widget.onCreated?.call(session);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New session'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(42),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (controller.loading) const LinearProgressIndicator(minHeight: 1),
            Expanded(
              child: RefreshIndicator(
                onRefresh: controller.loadSessions,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: visibleSessions.length,
                  itemBuilder: (context, index) {
                    final session = visibleSessions[index];
                    final selected = controller.selected?.id == session.id;
                    return ListTile(
                      selected: selected,
                      selectedTileColor: Colors.white.withValues(alpha: 0.05),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      leading: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 18,
                      ),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: session.updatedAt == null
                          ? null
                          : Text(
                              _relative(session.updatedAt!),
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                      onTap: () => onSelected(session),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _relative(DateTime date) {
    final difference = DateTime.now().difference(date.toLocal());
    if (difference.inMinutes < 1) return 'now';
    if (difference.inHours < 1) return '${difference.inMinutes}m';
    if (difference.inDays < 1) return '${difference.inHours}h';
    return '${difference.inDays}d';
  }
}

class MobileChatPage extends StatelessWidget {
  const MobileChatPage({super.key, required this.controller});
  final ChatController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(controller.selected?.title ?? 'Hermes')),
      body: ChatPane(controller: controller),
    ),
  );
}

class ChatPane extends StatefulWidget {
  const ChatPane({super.key, required this.controller});
  final ChatController controller;

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();
  bool _recording = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.selected == null) {
      return const Center(child: Text('Choose a session or start a new one.'));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
    return SafeArea(
      child: Column(
        children: [
          if (controller.error != null)
            MaterialBanner(
              content: Text(controller.error!),
              actions: [
                TextButton(
                  onPressed: controller.loadSessions,
                  child: const Text('Retry'),
                ),
              ],
            ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
              children: [
                ...groupTimeline(controller.messages).map(
                  (block) => switch (block) {
                    ToolGroupTimelineBlock() => ToolGroupTile(group: block),
                    MessageTimelineBlock(:final message) =>
                      message.event == null
                          ? MessageBubble(message: message)
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ToolEventTile(event: message.event!),
                            ),
                  },
                ),
                if (controller.sending)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (controller.pendingApproval case final request?)
            ApprovalCard(
              request: request,
              onChoice: controller.respondApproval,
            ),
          Container(
            constraints: const BoxConstraints(maxWidth: 920),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: _recording
                    ? 'Recording… tap stop when finished'
                    : controller.transcribing
                    ? 'Transcribing voice message…'
                    : 'Message Hermes…',
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: _recording
                          ? 'Stop and send recording'
                          : 'Record voice message',
                      onPressed: controller.sending || controller.transcribing
                          ? null
                          : _toggleRecording,
                      color: _recording ? Colors.redAccent : null,
                      icon: Icon(
                        _recording
                            ? Icons.stop_circle_outlined
                            : Icons.mic_none_rounded,
                      ),
                    ),
                    IconButton(
                      tooltip: controller.sending
                          ? 'Stop response'
                          : 'Send message',
                      onPressed: controller.transcribing || _recording
                          ? null
                          : controller.sending
                          ? controller.interrupt
                          : _send,
                      icon: Icon(
                        controller.sending
                            ? Icons.stop_circle_outlined
                            : Icons.arrow_upward_rounded,
                      ),
                    ),
                  ],
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleRecording() async {
    try {
      if (_recording) {
        final path = await _recorder.stop();
        if (mounted) setState(() => _recording = false);
        if (path == null) return;
        try {
          await widget.controller.sendVoice(path);
        } finally {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
        return;
      }

      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required.')),
          );
        }
        return;
      }
      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}/hermes-voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (mounted) setState(() => _recording = true);
    } catch (exception) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice recording failed: $exception')),
        );
      }
    }
  }

  void _send() {
    if (_recording ||
        widget.controller.sending ||
        widget.controller.transcribing) {
      return;
    }
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    widget.controller.send(text);
  }
}

class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.request,
    required this.onChoice,
  });

  final ApprovalRequest request;
  final ValueChanged<String> onChoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF221E16),
        border: Border.all(color: const Color(0xFF66542D)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Hermes needs your approval',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          if (request.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(request.description),
          ],
          if (request.command.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              request.command,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => onChoice('deny'),
                child: const Text('Deny'),
              ),
              FilledButton.tonal(
                onPressed: () => onChoice('once'),
                child: const Text('Allow once'),
              ),
              if (request.allowPermanent)
                FilledButton(
                  onPressed: () => onChoice('always'),
                  child: const Text('Always allow'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: user
              ? const Color(0xFF5E6AD2)
              : Colors.white.withValues(alpha: 0.035),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(message.text),
      ),
    );
  }
}
