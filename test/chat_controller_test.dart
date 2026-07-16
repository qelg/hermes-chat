import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/hermes_api.dart';
import 'package:hermes_chat/src/chat_controller.dart';
import 'package:hermes_chat/src/connection.dart';
import 'package:hermes_chat/src/models.dart';

void main() {
  test('tool events remain in chronological order across turns', () async {
    final api = _ConversationApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('First question');

    expect(controller.messages.map((message) => message.role), [
      'user',
      '_tool',
      '_tool',
      'assistant',
    ]);

    await controller.send('Second question');

    expect(controller.messages.map((message) => message.role), [
      'user',
      '_tool',
      '_tool',
      'assistant',
      'user',
      '_tool',
      '_tool',
      'assistant',
    ]);
    controller.dispose();
  });
  test('transcribes a recording before sending it as a user message', () async {
    final api = _ConversationApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.sendVoice('/tmp/voice.m4a');

    expect(api.transcribedPath, '/tmp/voice.m4a');
    expect(controller.messages.first.text, 'Voice transcript');
  });

  test('keeps a failed voice recording available for retry', () async {
    final api = _ConversationApi()..transcribeError = Exception('offline');
    final controller = ChatController(api)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    final sent = await controller.sendVoice('/tmp/voice.m4a');

    expect(sent, isFalse);
    expect(controller.transcribing, isFalse);
    expect(controller.voiceError, contains('offline'));

    controller.dismissVoiceError();
    expect(controller.voiceError, isNull);
  });

  test('surfaces and resolves Hermes tool approvals', () async {
    final api = _ConversationApi()..emitApproval = true;
    final controller = ChatController(api)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('Run it');
    expect(controller.pendingApproval?.command, 'sudo true');

    await controller.respondApproval('once');
    expect(api.approvalChoice, 'once');
    expect(controller.pendingApproval, isNull);
    controller.dispose();
  });
}

class _ConversationApi extends HermesApi {
  _ConversationApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  var turn = 0;
  bool emitApproval = false;
  String? approvalChoice;
  String? transcribedPath;
  Object? transcribeError;

  @override
  Future<String> transcribeAudio(String path) async {
    transcribedPath = path;
    if (transcribeError case final error?) throw error;
    return 'Voice transcript';
  }

  @override
  Future<void> respondApproval(ApprovalRequest request, String choice) async {
    approvalChoice = choice;
  }

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    turn += 1;
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.started',
        payload: {'tool_name': 'terminal', 'turn': turn},
      ),
    );
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.completed',
        payload: {'tool_name': 'terminal', 'turn': turn},
      ),
    );
    if (emitApproval) {
      yield const ApprovalUpdate(
        ApprovalRequest(
          sessionId: 'runtime-1',
          command: 'sudo true',
          description: 'Run command',
          allowPermanent: true,
        ),
      );
    }
    yield CompletedText('Answer $turn');
  }

  @override
  Future<List<HermesSession>> listSessions() async => [
    const HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}
