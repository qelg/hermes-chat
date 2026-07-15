import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/widgets/tool_event_tile.dart';
import 'package:hermes_chat/src/models.dart';

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
}
