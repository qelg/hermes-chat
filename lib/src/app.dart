import 'package:flutter/material.dart';

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
      if (config != null) await _connect(config, verify: false);
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<String?> _connect(
    ConnectionConfig config, {
    bool verify = true,
  }) async {
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
                  'Connect to your private Hermes API Server. Sessions stay native to Hermes—no messenger topics required.',
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
  final _token = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
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
              controller: _token,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API bearer token'),
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
            if (_url.text.trim().isEmpty || _token.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              ConnectionConfig(baseUrl: _url.text, token: _token.text),
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

class SessionSidebar extends StatelessWidget {
  const SessionSidebar({
    super.key,
    required this.controller,
    required this.onSelected,
    required this.onSettings,
  });
  final ChatController controller;
  final ValueChanged<HermesSession> onSelected;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
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
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: controller.createSession,
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
                  itemCount: controller.sessions.length,
                  itemBuilder: (context, index) {
                    final session = controller.sessions[index];
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(controller.selected?.title ?? 'Hermes')),
    body: ChatPane(controller: controller),
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

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
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
                ...controller.messages.map(
                  (message) => MessageBubble(message: message),
                ),
                if (controller.events.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      children: controller.events
                          .map((event) => ToolEventTile(event: event))
                          .toList(),
                    ),
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
          Container(
            constraints: const BoxConstraints(maxWidth: 920),
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: 'Message Hermes…',
                suffixIcon: IconButton(
                  onPressed: controller.sending ? null : _send,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
        ],
      ),
    );
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    widget.controller.send(text);
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
