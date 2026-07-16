import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/hermes_api.dart';
import 'package:hermes_chat/src/connection.dart';
import 'package:hermes_chat/src/models.dart';

void main() {
  test('lists Hermes serve sessions with preview text', () async {
    final transport = _FakeTransport()
      ..responses['session.list'] = {
        'sessions': [
          {'id': 'stored-1', 'title': 'Saved', 'preview': 'Preview text'},
        ],
      };
    final api = _api(transport);

    final sessions = await api.listSessions();

    expect(sessions.single.id, 'stored-1');
    expect(sessions.single.title, 'Saved');
    expect(sessions.single.preview, 'Preview text');
  });

  test(
    'fresh sessions keep their live runtime without premature resume',
    () async {
      final transport = _FakeTransport()
        ..responses['session.create'] = {
          'session_id': 'runtime-new',
          'stored_session_id': 'stored-new',
          'messages': <Object>[],
        };
      final api = _api(transport);

      final session = await api.createSession();
      final firstMessages = await api.messages(session.id);
      final secondMessages = await api.messages(session.id);

      expect(session.id, 'stored-new');
      expect(firstMessages, isEmpty);
      expect(secondMessages, isEmpty);
      expect(
        transport.calls.where((call) => call.$1 == 'session.resume'),
        isEmpty,
      );
    },
  );

  test(
    'fresh sessions load persisted REST history after the first prompt',
    () async {
      final transport = _FakeTransport()
        ..responses['session.create'] = {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-new',
        }
        ..histories['stored-new'] = [
          {'id': 1, 'role': 'assistant', 'content': 'Saved reply'},
        ];
      transport.onRequest = (method, params) {
        if (method == 'prompt.submit') {
          scheduleMicrotask(
            () => transport.emit('message.complete', {'text': 'Live reply'}),
          );
        }
      };
      final api = _api(transport);

      final session = await api.createSession();
      await api.chat(session.id, 'First message').toList();
      final messages = await api.messages(session.id);

      expect(messages.single.text, 'Saved reply');
      expect(
        transport.calls.where((call) => call.$1 == 'session.resume'),
        isEmpty,
      );
    },
  );

  test(
    'loads stored sessions from REST without activating a runtime',
    () async {
      final transport = _FakeTransport()
        ..histories['stored-1'] = [
          {'id': 1, 'role': 'user', 'content': 'Check it'},
          {
            'id': 2,
            'role': 'assistant',
            'content': '',
            'created_at': '2026-07-16T12:00:00.000Z',
            'tool_calls': [
              {
                'id': 'call-1',
                'function': {
                  'name': 'terminal',
                  'arguments': '{"command":"date"}',
                },
              },
            ],
          },
          {
            'id': 3,
            'role': 'tool',
            'tool_call_id': 'call-1',
            'tool_name': 'terminal',
            'content': '{"output":"ok"}',
            'created_at': '2026-07-16T12:00:00.001Z',
          },
          {'id': 4, 'role': 'assistant', 'content': 'Done'},
        ];
      final api = _api(transport);

      final messages = await api.messages('stored-1');

      expect(transport.historyCalls, ['stored-1']);
      expect(
        transport.calls.where((call) => call.$1 == 'session.resume'),
        isEmpty,
      );
      expect(messages.map((message) => message.role), [
        'user',
        '_tool',
        '_tool',
        'assistant',
      ]);
      expect(messages.map((message) => message.persistedId), [
        '1',
        '2',
        '3',
        '4',
      ]);
      final persistedDurations = messages
          .map((message) => message.event?.duration)
          .whereType<Duration>();
      expect(
        persistedDurations,
        isEmpty,
        reason: 'database flush timestamps must not become fake tool durations',
      );
    },
  );

  test(
    'REST grouped tool calls retain separate requests and results',
    () async {
      final transport = _FakeTransport()
        ..histories['stored-1'] = [
          {
            'role': 'assistant',
            'content': [
              for (var index = 1; index <= 4; index++)
                {
                  'type': 'tool_use',
                  'id': 'call-$index',
                  'name': 'terminal',
                  'input': {'command': 'request-$index'},
                },
            ],
          },
          for (var index = 1; index <= 4; index++)
            {
              'role': 'tool',
              'tool_call_id': 'call-$index',
              'tool_name': 'terminal',
              'content': 'result-$index',
            },
        ];
      final api = _api(transport);

      final messages = await api.messages('stored-1');
      final group = groupTimeline(messages).single as ToolGroupTimelineBlock;

      for (var index = 1; index <= 4; index++) {
        final events = group.events
            .where((event) => event.toolCallId == 'call-$index')
            .toList();
        expect(
          events.map((event) => event.toolState),
          ['started', 'completed'],
          reason: 'call-$index must expose a distinct request and result',
        );
        expect(events.first.details, contains('request-$index'));
        expect(events.last.details, contains('result-$index'));
      }
    },
  );

  test(
    'streams deltas tools approvals and final text over JSON-RPC events',
    () async {
      final transport = _FakeTransport();
      transport.responses['session.resume'] = {
        'session_id': 'runtime-1',
        'messages': <Object>[],
      };
      transport.onRequest = (method, params) {
        if (method != 'prompt.submit') return;
        scheduleMicrotask(() {
          transport.emit('message.delta', {'text': 'Hel'});
          transport.emit('tool.start', {
            'tool_id': 'call-1',
            'name': 'terminal',
          });
          transport.emit('approval.request', {
            'command': 'sudo true',
            'description': 'Run command',
            'allow_permanent': true,
          });
          transport.emit('tool.complete', {
            'tool_id': 'call-1',
            'name': 'terminal',
          });
          transport.emit('message.complete', {'text': 'Hello'});
        });
      };
      final api = _api(transport);

      final updates = await api.chat('stored-1', 'Hi').toList();

      expect(updates.whereType<TextDelta>().single.text, 'Hel');
      expect(updates.whereType<ToolUpdate>().length, 2);
      expect(
        updates.whereType<ApprovalUpdate>().single.request.command,
        'sudo true',
      );
      expect(updates.whereType<CompletedText>().single.text, 'Hello');
      expect(transport.paramsFor('prompt.submit'), {
        'session_id': 'runtime-1',
        'text': 'Hi',
      });
    },
  );

  test('resumes lazily and refreshes REST history before submit', () async {
    final transport = _FakeTransport()
      ..responses['session.resume'] = {'session_id': 'runtime-1'}
      ..histories['stored-1'] = [
        {'id': 7, 'role': 'assistant', 'content': 'External reply'},
      ];
    transport.onRequest = (method, params) {
      if (method == 'prompt.submit') {
        scheduleMicrotask(
          () => transport.emit('message.complete', {'text': 'Own reply'}),
        );
      }
    };
    final api = _api(transport);

    final updates = await api.chat('stored-1', 'Hi').toList();

    expect(
      updates.whereType<HistoryUpdate>().single.messages.single.text,
      'External reply',
    );
    expect(transport.operations, [
      'rpc:session.resume',
      'history:stored-1',
      'rpc:prompt.submit',
    ]);
  });

  test('responds to approvals on the runtime session', () async {
    final transport = _FakeTransport();
    final api = _api(transport);
    const request = ApprovalRequest(
      sessionId: 'runtime-7',
      command: 'rm file',
      description: 'Delete file',
      allowPermanent: false,
    );

    await api.respondApproval(request, 'once');

    expect(transport.paramsFor('approval.respond'), {
      'session_id': 'runtime-7',
      'choice': 'once',
    });
  });

  test(
    'REST history uses the encoded path, auth header, and messages list',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late Uri requestedUri;
      late String? sessionToken;
      final subscription = server.listen((request) async {
        requestedUri = request.uri;
        sessionToken = request.headers.value('X-Hermes-Session-Token');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"messages":[{"id":1,"role":"assistant","content":"Saved"}]}',
        );
        await request.response.close();
      });
      final transport = HermesServeTransport(
        ConnectionConfig(
          baseUrl: 'http://${server.address.host}:${server.port}',
          token: 'secret-test-token',
        ),
      );
      addTearDown(() async {
        await transport.close();
        await subscription.cancel();
        await server.close(force: true);
      });

      final rows = await transport.history('stored/session ?');

      expect(
        requestedUri.toString(),
        '/api/sessions/stored%2Fsession%20%3F/messages',
      );
      expect(sessionToken, 'secret-test-token');
      expect(rows.single['content'], 'Saved');
    },
  );

  test('REST history rejects a malformed messages payload', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"messages":{"not":"a list"}}');
      await request.response.close();
    });
    final transport = HermesServeTransport(
      ConnectionConfig(
        baseUrl: 'http://${server.address.host}:${server.port}',
        token: 'test',
      ),
    );
    addTearDown(() async {
      await transport.close();
      await subscription.cancel();
      await server.close(force: true);
    });

    await expectLater(
      transport.history('stored-1'),
      throwsA(
        isA<HermesStreamException>().having(
          (error) => error.message,
          'message',
          contains('messages list'),
        ),
      ),
    );
  });

  test('uses Hermes serve voice transcription', () async {
    final transport = _FakeTransport()..transcript = 'Transcribed voice';
    final api = _api(transport);

    final transcript = await api.transcribeAudio('/tmp/voice.m4a');

    expect(transcript, 'Transcribed voice');
    expect(transport.transcribedPath, '/tmp/voice.m4a');
  });

  test('voice transcription times out with an actionable error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestReceived = Completer<void>();
    final subscription = server.listen((request) async {
      await request.drain<void>();
      request.response.contentLength = 100;
      request.response.write('{');
      await request.response.flush();
      requestReceived.complete();
    });
    final recording = File('${Directory.systemTemp.path}/voice-timeout.m4a');
    await recording.writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112]);
    final transport = HermesServeTransport(
      ConnectionConfig(
        baseUrl: 'http://${server.address.host}:${server.port}',
        token: 'test',
      ),
      transcriptionTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(() async {
      await transport.close();
      await subscription.cancel();
      await server.close(force: true);
      if (await recording.exists()) await recording.delete();
    });

    await expectLater(
      transport
          .transcribeAudio(recording.path)
          .timeout(const Duration(milliseconds: 200)),
      throwsA(
        isA<HermesStreamException>().having(
          (error) => error.message,
          'message',
          contains('timed out'),
        ),
      ),
    );
    await requestReceived.future;
  });
}

HermesApi _api(_FakeTransport transport) => HermesApi(
  const ConnectionConfig(baseUrl: 'https://example.test', token: 'test'),
  transport: transport,
);

class _FakeTransport implements HermesTransport {
  final responses = <String, Map<String, dynamic>>{};
  final histories = <String, List<Map<String, dynamic>>>{};
  final calls = <(String, Map<String, dynamic>)>[];
  final historyCalls = <String>[];
  final operations = <String>[];
  final controller = StreamController<GatewayEvent>.broadcast();
  void Function(String, Map<String, dynamic>)? onRequest;
  String transcript = '';
  String? transcribedPath;

  @override
  Stream<GatewayEvent> get events => controller.stream;

  void emit(String type, Map<String, dynamic> payload) {
    controller.add(
      GatewayEvent(type: type, sessionId: 'runtime-1', payload: payload),
    );
  }

  Map<String, dynamic> paramsFor(String method) =>
      calls.lastWhere((call) => call.$1 == method).$2;

  @override
  Future<void> connect() async {}

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    operations.add('rpc:$method');
    calls.add((method, params));
    onRequest?.call(method, params);
    return responses[method] ?? <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> history(String sessionId) async {
    operations.add('history:$sessionId');
    historyCalls.add(sessionId);
    return histories[sessionId] ?? const [];
  }

  @override
  Future<String> transcribeAudio(String path) async {
    transcribedPath = path;
    return transcript;
  }

  @override
  Future<void> close() async {
    await controller.close();
  }
}
