import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/models.dart';

void main() {
  test('session accepts Hermes list response fields', () {
    final session = HermesSession.fromJson({
      'id': 'abc',
      'title': 'Build app',
      'updated_at': '2026-07-15T12:00:00Z',
      'source': 'api_server',
    });
    expect(session.id, 'abc');
    expect(session.title, 'Build app');
    expect(session.updatedAt, DateTime.utc(2026, 7, 15, 12));
  });

  test('tool events expose a compact summary and raw details', () {
    final event = ChatEvent.tool(
      type: 'tool.completed',
      payload: {'name': 'terminal', 'output': 'ok'},
    );
    expect(event.summary, contains('terminal'));
    expect(event.details, contains('"output": "ok"'));
  });
}
