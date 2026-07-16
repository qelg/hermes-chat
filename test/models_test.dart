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

  test('session search matches title and preview case-insensitively', () {
    const sessions = [
      HermesSession(id: '1', title: 'Zigbee repair', preview: 'Coordinator'),
      HermesSession(id: '2', title: 'Release app', preview: 'Android signing'),
    ];

    expect(filterSessions(sessions, 'zig').single.id, '1');
    expect(filterSessions(sessions, 'SIGNING').single.id, '2');
    expect(filterSessions(sessions, 'missing'), isEmpty);
  });

  test('tool events expose a compact summary and raw details', () {
    final event = ChatEvent.tool(
      type: 'tool.completed',
      payload: {'name': 'terminal', 'output': 'ok'},
    );
    expect(event.summary, contains('terminal'));
    expect(event.details, contains('"output": "ok"'));
  });
  test('groups four consecutive tool calls without changing chronology', () {
    ChatMessage tool(String state, String id, String name) => ChatMessage.tool(
      ChatEvent.tool(
        type: 'tool.$state',
        payload: {'tool_call_id': id, 'tool_name': name},
      ),
    );
    final messages = [
      const ChatMessage(role: 'user', text: 'Question'),
      tool('started', '1', 'terminal'),
      tool('completed', '1', 'terminal'),
      tool('started', '2', 'terminal'),
      tool('completed', '2', 'terminal'),
      tool('started', '3', 'terminal'),
      tool('completed', '3', 'terminal'),
      tool('started', '4', 'skill_view'),
      tool('completed', '4', 'skill_view'),
      const ChatMessage(role: 'assistant', text: 'Answer'),
    ];

    final blocks = groupTimeline(messages);

    expect(blocks.length, 3);
    expect((blocks[0] as MessageTimelineBlock).message.role, 'user');
    final tools = blocks[1] as ToolGroupTimelineBlock;
    expect(tools.events.length, 8);
    expect(tools.callCount, 4);
    expect(tools.counts, {'terminal': 3, 'skill_view': 1});
    expect((blocks[2] as MessageTimelineBlock).message.role, 'assistant');
  });
}
