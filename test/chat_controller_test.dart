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

  test('first message gives an untitled session a stable title', () async {
    final api = _ConversationApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Untitled session',
      );

    await controller.send('Fix session titles');

    expect(api.updatedTitle, 'Fix session titles');
    expect(controller.selected?.title, 'Fix session titles');
    controller.dispose();
  });
}

class _ConversationApi extends HermesApi {
  _ConversationApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  var turn = 0;
  String? updatedTitle;
  String? transcribedPath;

  @override
  Future<String> transcribeAudio(String path) async {
    transcribedPath = path;
    return 'Voice transcript';
  }

  @override
  Future<void> updateSessionTitle(String sessionId, String title) async {
    updatedTitle = title;
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
    yield CompletedText('Answer $turn');
  }

  @override
  Future<List<HermesSession>> listSessions() async => [
    HermesSession(id: 'session-1', title: updatedTitle ?? 'Existing session'),
  ];

  @override
  void close() {}
}
