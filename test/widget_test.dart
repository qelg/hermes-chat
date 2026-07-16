import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/hermes_api.dart';
import 'package:hermes_chat/src/app.dart';
import 'package:hermes_chat/src/chat_controller.dart';
import 'package:hermes_chat/src/connection.dart';
import 'package:hermes_chat/src/models.dart';
import 'package:hermes_chat/src/widgets/assistant_markdown.dart';
import 'package:hermes_chat/src/widgets/tool_event_tile.dart';

void main() {
  test('tool icons represent common families with a stable fallback', () {
    expect(toolIconForName('terminal'), Icons.terminal_rounded);
    expect(toolIconForName('functions.process'), Icons.terminal_rounded);
    expect(toolIconForName('read_file'), Icons.description_outlined);
    expect(toolIconForName('write_file'), Icons.edit_note_rounded);
    expect(toolIconForName('search_files'), Icons.folder_open_outlined);
    expect(toolIconForName('web_search'), Icons.public_rounded);
    expect(toolIconForName('github_pr_workflow'), Icons.account_tree_outlined);
    expect(toolIconForName('image_generate'), Icons.image_outlined);
    expect(toolIconForName('text_to_speech'), Icons.audio_file_outlined);
    expect(toolIconForName('cronjob'), Icons.calendar_month_outlined);
    expect(toolIconForName('brand_new_tool'), Icons.build_outlined);
  });

  testWidgets('tool tile uses its tool identifier for the leading icon', (
    tester,
  ) async {
    final event = ChatEvent.tool(
      type: 'tool.started',
      payload: {'tool_name': 'search_files'},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolEventTile(event: event)),
      ),
    );

    expect(find.byIcon(Icons.folder_open_outlined), findsOneWidget);
    expect(find.byIcon(Icons.terminal_rounded), findsNothing);
    expect(find.textContaining('search_files'), findsOneWidget);
  });

  testWidgets('tool details stay collapsed until tapped', (tester) async {
    final event = ChatEvent.tool(
      type: 'tool.completed',
      payload: {'name': 'terminal', 'output': 'secret detail'},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolEventTile(event: event)),
      ),
    );
    expect(find.text('secret detail'), findsNothing);
    await tester.tap(find.textContaining('terminal'));
    await tester.pumpAndSettle();
    expect(find.textContaining('secret detail'), findsOneWidget);
  });

  testWidgets('assistant messages show elapsed generation time', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: 'assistant',
              text: 'Done',
              duration: Duration(milliseconds: 3200),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Done'), findsOneWidget);
    expect(find.text('3.2 s'), findsOneWidget);
  });

  testWidgets('completed assistant messages render common Markdown', (
    tester,
  ) async {
    String? copiedCode;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedCode =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    const markdown = '''# Heading

A **bold** [link](https://example.com) with `inline code`.

[unsafe](javascript:alert(1)) <script>alert('no')</script>

- first
- second

> quote

| Column |
| --- |
| cell |

```dart
print('hello');
```
''';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(role: 'assistant', text: markdown),
          ),
        ),
      ),
    );

    expect(find.text('Heading'), findsOneWidget);
    expect(find.textContaining('bold', findRichText: true), findsOneWidget);
    expect(find.textContaining('link', findRichText: true), findsOneWidget);
    expect(find.text('cell'), findsOneWidget);
    expect(find.text(markdown), findsNothing);
    expect(find.byTooltip('Copy code'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(copiedCode, "print('hello');");
    expect(tester.takeException(), isNull);
  });

  test('assistant links reject executable and local URL schemes', () {
    expect(isSafeAssistantLink(Uri.parse('https://example.com')), isTrue);
    expect(isSafeAssistantLink(Uri.parse('mailto:team@example.com')), isTrue);
    expect(isSafeAssistantLink(Uri.parse('javascript:alert(1)')), isFalse);
    expect(isSafeAssistantLink(Uri.parse('file:///etc/passwd')), isFalse);
    expect(isSafeAssistantLink(Uri.parse('data:text/html,unsafe')), isFalse);
  });

  testWidgets('incomplete streaming Markdown renders without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MessageBubble(
              message: ChatMessage(
                role: 'assistant',
                text: 'Working **now\n\n```dart\nfinal value =',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('Working'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('user messages keep Markdown as literal text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(role: 'user', text: '**do not render**'),
          ),
        ),
      ),
    );

    expect(find.text('**do not render**'), findsOneWidget);
  });

  testWidgets('tool groups summarize actual calls by tool type', (
    tester,
  ) async {
    ChatEvent event(String state, String id, String name) => ChatEvent.tool(
      type: 'tool.$state',
      payload: {'tool_call_id': id, 'tool_name': name},
    );
    final group = ToolGroupTimelineBlock([
      event('started', '1', 'terminal'),
      event('completed', '1', 'terminal'),
      event('started', '2', 'terminal'),
      event('completed', '2', 'terminal'),
      event('started', '3', 'skill_view'),
      event('completed', '3', 'skill_view'),
      event('started', '4', 'search_files'),
      event('completed', '4', 'search_files'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolGroupTile(group: group)),
      ),
    );

    expect(find.text('4 tool calls'), findsOneWidget);
    expect(find.textContaining('terminal ×2'), findsOneWidget);
    expect(find.textContaining('skill_view ×1'), findsOneWidget);
  });

  testWidgets('voice transcription shows progress and retry actions', (
    tester,
  ) async {
    var retried = false;
    var discarded = false;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VoiceStatusPanel(transcribing: true)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.text('Uploading and transcribing voice message…'),
      findsOneWidget,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoiceStatusPanel(
            error: 'Voice transcription timed out',
            onRetry: () => retried = true,
            onDiscard: () => discarded = true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Discard'));
    expect(retried, isTrue);
    expect(discarded, isTrue);
  });

  testWidgets('session search filters titles and preview text', (tester) async {
    final controller = ChatController(_FakeHermesApi())
      ..sessions = const [
        HermesSession(id: '1', title: 'Zigbee repair'),
        HermesSession(
          id: '2',
          title: 'Android release',
          preview: 'Signing certificate',
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionSidebar(
            controller: controller,
            onSelected: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Search sessions'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'signing');
    await tester.pump();

    expect(find.text('Android release'), findsOneWidget);
    expect(find.text('Zigbee repair'), findsNothing);
    controller.dispose();
  });

  testWidgets('new session opens the chat immediately on mobile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ChatController(_CreatingHermesApi());

    await tester.pumpWidget(
      MaterialApp(
        home: ChatShell(controller: controller, onSettings: () {}),
      ),
    );
    await tester.tap(find.text('New session'));
    await tester.pumpAndSettle();

    expect(controller.error, isNull);
    expect(controller.selected?.id, 'new-session');
    expect(find.byType(MobileChatPage), findsOneWidget);
    controller.dispose();
  });

  testWidgets('approval card exposes deny once and permanent choices', (
    tester,
  ) async {
    String? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ApprovalCard(
            request: const ApprovalRequest(
              sessionId: 'runtime-1',
              command: 'sudo true',
              description: 'Run command',
              allowPermanent: true,
            ),
            onChoice: (value) => choice = value,
          ),
        ),
      ),
    );

    expect(find.text('Deny'), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    expect(choice, 'once');
  });

  testWidgets('mobile chat rebuilds when the controller emits an update', (
    tester,
  ) async {
    final controller = ChatController(_FakeHermesApi())
      ..selected = const HermesSession(id: 'session-1', title: 'Test')
      ..messages = const [ChatMessage(role: 'user', text: 'Before')];

    await tester.pumpWidget(
      MaterialApp(home: MobileChatPage(controller: controller)),
    );
    expect(find.text('Before'), findsOneWidget);

    controller.messages = const [
      ChatMessage(role: 'user', text: 'Before'),
      ChatMessage(role: 'assistant', text: 'After'),
    ];
    controller.notifyListeners();
    await tester.pump();

    expect(find.text('After'), findsOneWidget);
    controller.dispose();
  });
}

class _CreatingHermesApi extends _FakeHermesApi {
  @override
  Future<HermesSession> createSession({String? title}) async =>
      const HermesSession(id: 'new-session', title: 'Untitled session');

  @override
  Future<List<ChatMessage>> messages(String sessionId) async => const [];
}

class _FakeHermesApi extends HermesApi {
  _FakeHermesApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  @override
  void close() {}
}
