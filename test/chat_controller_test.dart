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
  test('tracks parallel tool durations by call id', () async {
    var elapsed = Duration.zero;
    final api = _TimedConversationApi((duration) => elapsed += duration);
    final controller = ChatController(api, elapsed: () => elapsed)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('Run both');

    final completed = {
      for (final message in controller.messages)
        if (message.event case final event? when event.toolState == 'completed')
          event.toolCallId: event.duration,
    };
    expect(completed['call-a'], const Duration(seconds: 5));
    expect(completed['call-b'], const Duration(seconds: 2));
    final assistant = controller.messages.last;
    expect(assistant.role, 'assistant');
    expect(assistant.duration, const Duration(milliseconds: 3200));
    controller.dispose();
  });

  test('marks unfinished tools failed with their elapsed duration', () async {
    var elapsed = Duration.zero;
    final api = _FailingConversationApi((duration) => elapsed += duration);
    final controller = ChatController(api, elapsed: () => elapsed)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('Fail');

    final events = controller.messages
        .map((message) => message.event)
        .whereType<ChatEvent>()
        .toList();
    expect(events.map((event) => event.toolState), ['started', 'failed']);
    expect(events.last.duration, const Duration(milliseconds: 1500));
    final assistant = controller.messages.singleWhere(
      (message) => message.role == 'assistant',
    );
    expect(assistant.text, 'Partial');
    expect(assistant.duration, Duration.zero);
    expect(controller.error, contains('boom'));
    controller.dispose();
  });

  test('marks unfinished tools cancelled when the stream stops', () async {
    var elapsed = Duration.zero;
    final api = _CancelledConversationApi((duration) => elapsed += duration);
    final controller = ChatController(api, elapsed: () => elapsed)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('Cancel');

    final events = controller.messages
        .map((message) => message.event)
        .whereType<ChatEvent>()
        .toList();
    expect(events.map((event) => event.toolState), ['started', 'cancelled']);
    expect(events.last.duration, const Duration(milliseconds: 750));
    controller.dispose();
  });

  test(
    'excludes intervening tool time from text generation duration',
    () async {
      var elapsed = Duration.zero;
      final api = _InterleavedConversationApi(
        (duration) => elapsed += duration,
      );
      final controller = ChatController(api, elapsed: () => elapsed)
        ..selected = const HermesSession(
          id: 'session-1',
          title: 'Existing session',
        );

      await controller.send('Think and run');

      final assistant = controller.messages.last;
      expect(assistant.role, 'assistant');
      expect(assistant.duration, const Duration(seconds: 3));
      controller.dispose();
    },
  );

  test('keeps generation paused for text deltas while tools run', () async {
    var elapsed = Duration.zero;
    final api = _TextDuringToolApi((duration) => elapsed += duration);
    final controller = ChatController(api, elapsed: () => elapsed)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('Run and report');

    final assistant = controller.messages.last;
    expect(assistant.role, 'assistant');
    expect(assistant.duration, const Duration(seconds: 2));
    controller.dispose();
  });

  test(
    'times completion-only assistant responses from request start',
    () async {
      var elapsed = Duration.zero;
      final api = _CompletionOnlyApi((duration) => elapsed += duration);
      final controller = ChatController(api, elapsed: () => elapsed)
        ..selected = const HermesSession(
          id: 'session-1',
          title: 'Existing session',
        );

      await controller.send('Answer');

      expect(controller.messages.last.duration, const Duration(seconds: 2));
      controller.dispose();
    },
  );

  test('keeps first timestamp when a tool start is duplicated', () async {
    var elapsed = Duration.zero;
    final api = _DuplicateToolStartApi((duration) => elapsed += duration);
    final controller = ChatController(api, elapsed: () => elapsed)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('Run once');

    final completed = controller.messages
        .map((message) => message.event)
        .whereType<ChatEvent>()
        .singleWhere((event) => event.toolState == 'completed');
    expect(completed.duration, const Duration(seconds: 3));
    controller.dispose();
  });

  test('times explicit failed and cancelled tool updates once', () async {
    var elapsed = Duration.zero;
    final api = _ExplicitTerminalToolApi((duration) => elapsed += duration);
    final controller = ChatController(api, elapsed: () => elapsed)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      );

    await controller.send('Run both');

    final events = controller.messages
        .map((message) => message.event)
        .whereType<ChatEvent>()
        .toList();
    expect(events.map((event) => event.toolState), [
      'started',
      'failed',
      'started',
      'cancelled',
    ]);
    expect(events[1].duration, const Duration(seconds: 1));
    expect(events[3].duration, const Duration(seconds: 2));
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

class _InterleavedConversationApi extends HermesApi {
  _InterleavedConversationApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield const TextDelta('Thinking');
    advance(const Duration(seconds: 1));
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.started',
        payload: {'tool_call_id': 'call-tool', 'tool_name': 'terminal'},
      ),
    );
    advance(const Duration(seconds: 5));
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.completed',
        payload: {'tool_call_id': 'call-tool', 'tool_name': 'terminal'},
      ),
    );
    advance(const Duration(seconds: 2));
    yield const CompletedText('Done');
  }

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _TextDuringToolApi extends HermesApi {
  _TextDuringToolApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    const payload = {'tool_call_id': 'call-tool', 'tool_name': 'terminal'};
    yield ToolUpdate(ChatEvent.tool(type: 'tool.started', payload: payload));
    advance(const Duration(seconds: 1));
    yield const TextDelta('Still working');
    advance(const Duration(seconds: 4));
    yield ToolUpdate(ChatEvent.tool(type: 'tool.completed', payload: payload));
    advance(const Duration(seconds: 2));
    yield const CompletedText('Done');
  }

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _CompletionOnlyApi extends HermesApi {
  _CompletionOnlyApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    advance(const Duration(seconds: 2));
    yield const CompletedText('Done');
  }

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _DuplicateToolStartApi extends HermesApi {
  _DuplicateToolStartApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    const payload = {'tool_call_id': 'call-once', 'tool_name': 'terminal'};
    yield ToolUpdate(ChatEvent.tool(type: 'tool.started', payload: payload));
    advance(const Duration(seconds: 1));
    yield ToolUpdate(ChatEvent.tool(type: 'tool.started', payload: payload));
    advance(const Duration(seconds: 2));
    yield ToolUpdate(ChatEvent.tool(type: 'tool.completed', payload: payload));
  }

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _ExplicitTerminalToolApi extends HermesApi {
  _ExplicitTerminalToolApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    for (final state in ['failed', 'cancelled']) {
      final id = 'call-$state';
      yield ToolUpdate(
        ChatEvent.tool(
          type: 'tool.started',
          payload: {'tool_call_id': id, 'tool_name': 'terminal'},
        ),
      );
      advance(Duration(seconds: state == 'failed' ? 1 : 2));
      yield ToolUpdate(
        ChatEvent.tool(
          type: 'tool.$state',
          payload: {'tool_call_id': id, 'tool_name': 'terminal'},
        ),
      );
    }
  }

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _CancelledConversationApi extends HermesApi {
  _CancelledConversationApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.started',
        payload: {'tool_call_id': 'call-cancelled', 'tool_name': 'terminal'},
      ),
    );
    advance(const Duration(milliseconds: 750));
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) async => const [];

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _FailingConversationApi extends HermesApi {
  _FailingConversationApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.started',
        payload: {'tool_call_id': 'call-failed', 'tool_name': 'terminal'},
      ),
    );
    advance(const Duration(milliseconds: 500));
    yield const TextDelta('Partial');
    advance(const Duration(seconds: 1));
    throw Exception('boom');
  }

  @override
  void close() {}
}

class _TimedConversationApi extends HermesApi {
  _TimedConversationApi(this.advance)
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final void Function(Duration) advance;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.started',
        payload: {'tool_call_id': 'call-a', 'tool_name': 'terminal'},
      ),
    );
    advance(const Duration(seconds: 1));
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.started',
        payload: {'tool_call_id': 'call-b', 'tool_name': 'search_files'},
      ),
    );
    advance(const Duration(seconds: 2));
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.completed',
        payload: {'tool_call_id': 'call-b', 'tool_name': 'search_files'},
      ),
    );
    advance(const Duration(seconds: 2));
    yield ToolUpdate(
      ChatEvent.tool(
        type: 'tool.completed',
        payload: {'tool_call_id': 'call-a', 'tool_name': 'terminal'},
      ),
    );
    yield const TextDelta('D');
    advance(const Duration(milliseconds: 3200));
    yield const CompletedText('Done');
  }

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
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
