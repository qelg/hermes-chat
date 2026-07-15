import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/hermes_api.dart';
import 'package:hermes_chat/src/connection.dart';
import 'package:http/http.dart' as http;

void main() {
  test('reads sessions from the Hermes list data field', () async {
    final api = HermesApi(
      const ConnectionConfig(baseUrl: 'https://example.test', token: 'token'),
      client: _StreamClient(
        '{"object":"list","data":[{"id":"session-1","title":"Saved"}]}',
        contentType: 'application/json',
      ),
    );

    final sessions = await api.listSessions();

    expect(sessions.single.id, 'session-1');
    expect(sessions.single.title, 'Saved');
  });

  test('reads message history from the Hermes list data field', () async {
    final api = HermesApi(
      const ConnectionConfig(baseUrl: 'https://example.test', token: 'token'),
      client: _StreamClient(
        '{"object":"list","data":[{"role":"assistant","content":"Saved reply"}]}',
        contentType: 'application/json',
      ),
    );

    final messages = await api.messages('session-1');

    expect(messages.single.role, 'assistant');
    expect(messages.single.text, 'Saved reply');
  });

  test(
    'restores tool calls in their persisted chronological positions',
    () async {
      final api = HermesApi(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'token'),
        client: _StreamClient('''{"object":"list","data":[
          {"role":"user","content":"Check it"},
          {"role":"assistant","content":"","tool_calls":[{"id":"call-1","function":{"name":"terminal","arguments":"{\\"command\\":\\"date\\"}"}}]},
          {"role":"tool","tool_call_id":"call-1","tool_name":"terminal","content":"{\\"output\\":\\"ok\\"}"},
          {"role":"assistant","content":"Done"}
        ]}''', contentType: 'application/json'),
      );

      final messages = await api.messages('session-1');

      expect(messages.map((message) => message.role), [
        'user',
        '_tool',
        '_tool',
        'assistant',
      ]);
      expect(messages[1].event!.summary, 'terminal · started');
      expect(messages[2].event!.summary, 'terminal · completed');
    },
  );

  test(
    'session stream exposes final assistant content even without deltas',
    () async {
      final client = _StreamClient('''
event: run.started
data: {"run_id":"run-1"}

event: assistant.completed
data: {"content":"Final answer","completed":true}

event: run.completed
data: {"completed":true}

event: done
data: {}

''');
      final api = HermesApi(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'token'),
        client: client,
      );

      final updates = await api.chat('session-1', 'Hello').toList();

      expect(updates.whereType<CompletedText>().single.text, 'Final answer');
      expect(jsonDecode(client.lastBody!), {'input': 'Hello'});
    },
  );

  test('session stream surfaces server-side agent errors', () async {
    final api = HermesApi(
      const ConnectionConfig(baseUrl: 'https://example.test', token: 'token'),
      client: _StreamClient('''
event: error
data: {"message":"Provider unavailable"}

event: done
data: {}

'''),
    );

    expect(
      () => api.chat('session-1', 'Hello').toList(),
      throwsA(isA<HermesStreamException>()),
    );
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.sse, {this.contentType = 'text/event-stream'});

  final String sse;
  final String contentType;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastBody = request is http.Request ? request.body : '';
    return http.StreamedResponse(
      Stream.value(utf8.encode(sse)),
      200,
      headers: {'content-type': contentType},
    );
  }
}
