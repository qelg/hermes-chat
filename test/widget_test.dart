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
