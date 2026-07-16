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
    'fresh sessions become resumable after the first prompt is accepted',
    () async {
      final transport = _FakeTransport()
        ..responses['session.create'] = {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-new',
        }
        ..responses['session.resume'] = {
          'session_id': 'runtime-2',
          'messages': [
            {'role': 'assistant', 'content': 'Saved reply'},
          ],
        };
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
        transport.calls.where((call) => call.$1 == 'session.resume').length,
        1,
      );
    },
  );

  test(
    'resumes stored sessions and restores chronological tool history',
    () async {
      final transport = _FakeTransport()
        ..responses['session.resume'] = {
          'session_id': 'runtime-1',
          'stored_session_id': 'stored-1',
          'messages': [
            {'role': 'user', 'content': 'Check it'},
            {
              'role': 'assistant',
              'content': '',
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
              'role': 'tool',
              'tool_call_id': 'call-1',
              'tool_name': 'terminal',
              'content': '{"output":"ok"}',
            },
            {'role': 'assistant', 'content': 'Done'},
          ],
        };
      final api = _api(transport);

      final messages = await api.messages('stored-1');

      expect(transport.paramsFor('session.resume')['session_id'], 'stored-1');
      expect(messages.map((message) => message.role), [
        'user',
        '_tool',
        '_tool',
        'assistant',
      ]);
    },
  );

  test(
    'resumed grouped tool calls retain separate requests and results',
    () async {
      final transport = _FakeTransport()
        ..responses['session.resume'] = {
          'session_id': 'runtime-1',
          'messages': [
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
          ],
        };
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
  final calls = <(String, Map<String, dynamic>)>[];
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
    calls.add((method, params));
    onRequest?.call(method, params);
    return responses[method] ?? <String, dynamic>{};
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
