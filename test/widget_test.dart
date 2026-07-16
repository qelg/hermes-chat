import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/hermes_api.dart';
import 'package:hermes_chat/src/app.dart';
import 'package:hermes_chat/src/chat_controller.dart';
import 'package:hermes_chat/src/connection.dart';
import 'package:hermes_chat/src/models.dart';
import 'package:hermes_chat/src/widgets/tool_event_tile.dart';

void main() {
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

class _FakeHermesApi extends HermesApi {
  _FakeHermesApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  @override
  void close() {}
}
