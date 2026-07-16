import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/hermes_api.dart';
import 'package:hermes_chat/src/chat_controller.dart';
import 'package:hermes_chat/src/connection.dart';
import 'package:hermes_chat/src/models.dart';

void main() {
  test('visible chats periodically reconcile canonical REST history', () async {
    final api = _RefreshingApi();
    final controller = ChatController(
      api,
      refreshInterval: const Duration(milliseconds: 10),
    );
    const session = HermesSession(id: 'session-1', title: 'Existing session');

    await controller.select(session);
    expect(controller.messages.map((message) => message.text), ['Initial']);

    api.history = const [
      ChatMessage(role: 'assistant', text: 'Initial'),
      ChatMessage(role: 'user', text: 'External message'),
    ];
    await api.periodicRead.future;
    await Future<void>.delayed(Duration.zero);

    expect(controller.messages.map((message) => message.text), [
      'Initial',
      'External message',
    ]);
    controller.dispose();
  });

  test('stale post-completion history does not erase the local turn', () async {
    final api = _StaleCompletionHistoryApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      )
      ..messages = const [
        ChatMessage(role: 'assistant', text: 'Initial', persistedId: '1'),
      ];

    await controller.send('Own question');

    expect(controller.messages.map((message) => message.text), [
      'Initial',
      'External reply',
      'Own question',
      'Own reply',
    ]);

    api.history = const [
      ..._StaleCompletionHistoryApi.canonicalBeforeOwnTurn,
      ChatMessage(role: 'user', text: 'Own question', persistedId: '3'),
      ChatMessage(role: 'assistant', text: 'Own reply', persistedId: '4'),
    ];
    await controller.refreshHistory(force: true);

    expect(controller.messages.map((message) => message.text), [
      'Initial',
      'External reply',
      'Own question',
      'Own reply',
    ]);
    expect(
      controller.messages.every((message) => message.persistedId != null),
      isTrue,
    );
    controller.dispose();
  });

  test(
    'a refresh started before send cannot overwrite the live turn',
    () async {
      final api = _OverlappingRefreshApi();
      final controller = ChatController(api)
        ..selected = const HermesSession(
          id: 'session-1',
          title: 'Existing session',
        )
        ..messages = const [
          ChatMessage(role: 'assistant', text: 'Initial', persistedId: '1'),
        ];

      final staleRefresh = controller.refreshHistory();
      final send = controller.send('Own question');
      api.staleRefresh.complete(const [
        ChatMessage(role: 'assistant', text: 'Initial', persistedId: '1'),
      ]);
      await staleRefresh;
      await api.completionRefreshStarted.future;
      await send;

      expect(api.historyCalls, 2);
      expect(controller.messages.map((message) => message.text), [
        'Initial',
        'Own question',
        'Own reply',
      ]);
      expect(
        controller.messages.every((message) => message.persistedId != null),
        isTrue,
      );
      controller.dispose();
    },
  );

  test('select ignores stale history from a previous session', () async {
    final api = _DeferredHistoryApi();
    final controller = ChatController(api);
    const first = HermesSession(id: 'first', title: 'First');
    const second = HermesSession(id: 'second', title: 'Second');

    final selectingFirst = controller.select(first);
    final selectingSecond = controller.select(second);
    api.complete('first', 'First history');
    await selectingFirst;
    expect(controller.selected, second);
    expect(controller.loading, isTrue);

    api.complete('second', 'Second history');
    await selectingSecond;

    expect(controller.selected, second);
    expect(controller.loading, isFalse);
    expect(controller.messages.single.text, 'Second history');
    controller.dispose();
  });

  test('session reload ignores a list made stale by selection', () async {
    final api = _StaleSessionListApi();
    const first = HermesSession(id: 'first', title: 'First');
    const second = HermesSession(id: 'second', title: 'Second');
    final controller = ChatController(api)
      ..selected = first
      ..sessions = const [first, second];

    final reload = controller.loadSessions();
    await api.listRequested.future;
    await controller.select(second);
    api.releaseList.complete(const [first]);
    await reload;

    expect(controller.selected, second);
    expect(controller.sessions, contains(second));
    expect(controller.loading, isFalse);
    controller.dispose();
  });

  test(
    'disposing during history load does not notify or start a timer',
    () async {
      final api = _DeferredHistoryApi();
      final controller = ChatController(
        api,
        refreshInterval: const Duration(milliseconds: 1),
      );

      final selecting = controller.select(
        const HermesSession(id: 'first', title: 'First'),
      );
      controller.dispose();
      api.complete('first', 'Late history');

      await expectLater(selecting, completes);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(api.historyCalls, 1);
    },
  );

  test('successful WebSocket reconnect reconciles visible history', () async {
    final api = _ReconnectApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(
        id: 'session-1',
        title: 'Existing session',
      )
      ..messages = const [ChatMessage(role: 'assistant', text: 'Initial')];

    api.history = const [
      ChatMessage(role: 'assistant', text: 'Initial'),
      ChatMessage(role: 'user', text: 'After reconnect'),
    ];
    api.emitReconnect();
    await api.refreshObserved.future;
    await Future<void>.delayed(Duration.zero);

    expect(controller.messages.map((message) => message.text), [
      'Initial',
      'After reconnect',
    ]);
    controller.dispose();
  });

  test('disconnect errors do not prevent reconnect reconciliation', () async {
    final api = _ReconnectApi();
    final uncaught = <Object>[];

    await runZonedGuarded(() async {
      final controller = ChatController(api)
        ..selected = const HermesSession(
          id: 'session-1',
          title: 'Existing session',
        )
        ..messages = const [ChatMessage(role: 'assistant', text: 'Initial')];
      api.emitDisconnectError();
      await Future<void>.delayed(Duration.zero);

      api.history = const [
        ChatMessage(role: 'assistant', text: 'Initial'),
        ChatMessage(role: 'user', text: 'After reconnect'),
      ];
      api.emitReconnect();
      await api.refreshObserved.future;
      await Future<void>.delayed(Duration.zero);

      expect(controller.messages.last.text, 'After reconnect');
      controller.dispose();
    }, (error, _) => uncaught.add(error));

    expect(uncaught, isEmpty);
  });

  test('switching sessions while sending cannot mutate the new chat', () async {
    final api = _SessionSwitchDuringSendApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(id: 'first', title: 'First')
      ..messages = const [
        ChatMessage(role: 'assistant', text: 'First history', persistedId: '1'),
      ];

    final sending = controller.send('Question for first');
    await api.streamStarted.future;
    await controller.select(const HermesSession(id: 'second', title: 'Second'));
    api.releaseStream.complete();
    await sending;

    expect(controller.selected?.id, 'second');
    expect(controller.messages.map((message) => message.text), [
      'Second history',
    ]);
    controller.dispose();
  });

  test('obsolete send cannot reconcile sessions after a switch', () async {
    final api = _SwitchDuringFinalReconciliationApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(id: 'first', title: 'First')
      ..messages = const [
        ChatMessage(role: 'assistant', text: 'First history', persistedId: '1'),
      ];

    final sending = controller.send('Question for first');
    await api.finalRefreshStarted.future;
    await controller.select(const HermesSession(id: 'second', title: 'Second'));
    api.releaseFinalRefresh.complete(const [
      ChatMessage(role: 'user', text: 'Question for first', persistedId: '2'),
      ChatMessage(role: 'assistant', text: 'First reply', persistedId: '3'),
    ]);
    await sending;

    expect(api.listSessionsCalls, 0);
    expect(controller.selected?.id, 'second');
    expect(controller.messages.map((message) => message.text), [
      'Second history',
    ]);
    controller.dispose();
  });

  test('switching sessions releases send ownership for the new chat', () async {
    final api = _SendOwnershipApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(id: 'first', title: 'First');

    final firstSend = controller.send('Question for first');
    await api.firstStreamStarted.future;
    await controller.select(const HermesSession(id: 'second', title: 'Second'));
    final secondSend = controller.send('Question for second');
    await api.secondStreamStarted.future;
    api.releaseFirstStream.complete();
    await firstSend;

    expect(controller.sending, isTrue);
    api.releaseSecondStream.complete();
    await secondSend;

    expect(api.sentSessions, ['first', 'second']);
    expect(controller.selected?.id, 'second');
    expect(controller.messages.last.text, 'Second reply');
    expect(controller.sending, isFalse);
    controller.dispose();
  });

  test('switching away and back cannot start a duplicate send', () async {
    final api = _SendOwnershipApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(id: 'first', title: 'First');

    final firstSend = controller.send('First question');
    await api.firstStreamStarted.future;
    await controller.select(const HermesSession(id: 'second', title: 'Second'));
    await controller.select(const HermesSession(id: 'first', title: 'First'));

    expect(controller.sending, isTrue);
    await controller.send('Duplicate question');
    expect(api.sentSessions, ['first']);

    api.releaseFirstStream.complete();
    await firstSend;
    expect(controller.sending, isFalse);
    controller.dispose();
  });

  test('switching sessions clears an approval from the old chat', () async {
    final api = _ApprovalDuringSwitchApi();
    final controller = ChatController(api)
      ..selected = const HermesSession(id: 'first', title: 'First');

    final sending = controller.send('Run command');
    await api.approvalEmitted.future;
    expect(controller.pendingApproval?.command, 'sudo true');

    await controller.select(const HermesSession(id: 'second', title: 'Second'));
    expect(controller.pendingApproval, isNull);
    await controller.respondApproval('once');
    expect(api.approvalChoices, isEmpty);

    api.releaseStream.complete();
    await sending;
    controller.dispose();
  });

  test(
    'an old approval response cannot surface an error in a new chat',
    () async {
      final api = _ApprovalDuringSwitchApi();
      final controller = ChatController(api)
        ..selected = const HermesSession(id: 'first', title: 'First');

      final sending = controller.send('Run command');
      await api.approvalEmitted.future;
      final responding = controller.respondApproval('once');
      await api.approvalResponseStarted.future;

      await controller.select(
        const HermesSession(id: 'second', title: 'Second'),
      );
      api.releaseApprovalResponse.completeError(Exception('late failure'));
      await responding;

      expect(controller.selected?.id, 'second');
      expect(controller.pendingApproval, isNull);
      expect(controller.error, isNull);
      api.releaseStream.complete();
      await sending;
      controller.dispose();
    },
  );

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

class _RefreshingApi extends HermesApi {
  _RefreshingApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  List<ChatMessage> history = const [
    ChatMessage(role: 'assistant', text: 'Initial'),
  ];
  final periodicRead = Completer<void>();
  var historyCalls = 0;

  @override
  Future<List<ChatMessage>> messages(String sessionId) async {
    historyCalls += 1;
    if (historyCalls > 1 && !periodicRead.isCompleted) periodicRead.complete();
    return history;
  }

  @override
  void close() {}
}

class _StaleCompletionHistoryApi extends HermesApi {
  _StaleCompletionHistoryApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  static const canonicalBeforeOwnTurn = [
    ChatMessage(role: 'assistant', text: 'Initial', persistedId: '1'),
    ChatMessage(role: 'assistant', text: 'External reply', persistedId: '2'),
  ];
  List<ChatMessage> history = canonicalBeforeOwnTurn;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield const HistoryUpdate(canonicalBeforeOwnTurn);
    yield const CompletedText('Own reply');
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) async => history;

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _OverlappingRefreshApi extends HermesApi {
  _OverlappingRefreshApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final staleRefresh = Completer<List<ChatMessage>>();
  final completionRefreshStarted = Completer<void>();
  var historyCalls = 0;

  @override
  Future<List<ChatMessage>> messages(String sessionId) {
    historyCalls += 1;
    if (historyCalls == 1) return staleRefresh.future;
    if (!completionRefreshStarted.isCompleted) {
      completionRefreshStarted.complete();
    }
    return Future.value(const [
      ChatMessage(role: 'assistant', text: 'Initial', persistedId: '1'),
      ChatMessage(role: 'user', text: 'Own question', persistedId: '2'),
      ChatMessage(role: 'assistant', text: 'Own reply', persistedId: '3'),
    ]);
  }

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield const HistoryUpdate([
      ChatMessage(role: 'assistant', text: 'Initial', persistedId: '1'),
    ]);
    yield const CompletedText('Own reply');
  }

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'session-1', title: 'Existing session'),
  ];

  @override
  void close() {}
}

class _DeferredHistoryApi extends HermesApi {
  _DeferredHistoryApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final requests = <String, Completer<List<ChatMessage>>>{};
  var historyCalls = 0;

  @override
  Future<List<ChatMessage>> messages(String sessionId) {
    historyCalls += 1;
    return (requests[sessionId] ??= Completer<List<ChatMessage>>()).future;
  }

  void complete(String sessionId, String text) {
    requests[sessionId]!.complete([ChatMessage(role: 'assistant', text: text)]);
  }

  @override
  void close() {}
}

class _StaleSessionListApi extends HermesApi {
  _StaleSessionListApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final listRequested = Completer<void>();
  final releaseList = Completer<List<HermesSession>>();

  @override
  Future<List<HermesSession>> listSessions() {
    listRequested.complete();
    return releaseList.future;
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) async => const [
    ChatMessage(role: 'assistant', text: 'Second history', persistedId: '2'),
  ];

  @override
  void close() {}
}

class _ReconnectApi extends HermesApi {
  _ReconnectApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final reconnectController = StreamController<void>.broadcast();
  final refreshObserved = Completer<void>();
  List<ChatMessage> history = const [];

  @override
  Stream<void> get reconnections => reconnectController.stream;

  void emitReconnect() => reconnectController.add(null);

  void emitDisconnectError() {
    reconnectController.addError(Exception('disconnected'));
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) async {
    if (!refreshObserved.isCompleted) refreshObserved.complete();
    return history;
  }

  @override
  void close() {
    unawaited(reconnectController.close());
  }
}

class _SessionSwitchDuringSendApi extends HermesApi {
  _SessionSwitchDuringSendApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final streamStarted = Completer<void>();
  final releaseStream = Completer<void>();

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield const HistoryUpdate([
      ChatMessage(role: 'assistant', text: 'First history', persistedId: '1'),
    ]);
    streamStarted.complete();
    await releaseStream.future;
    yield const CompletedText('Late reply for first');
  }

  @override
  Future<List<ChatMessage>> messages(
    String sessionId,
  ) async => switch (sessionId) {
    'first' => const [
      ChatMessage(role: 'assistant', text: 'First history', persistedId: '1'),
    ],
    _ => const [
      ChatMessage(role: 'assistant', text: 'Second history', persistedId: '2'),
    ],
  };

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'first', title: 'First'),
    HermesSession(id: 'second', title: 'Second'),
  ];

  @override
  void close() {}
}

class _SwitchDuringFinalReconciliationApi extends HermesApi {
  _SwitchDuringFinalReconciliationApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final finalRefreshStarted = Completer<void>();
  final releaseFinalRefresh = Completer<List<ChatMessage>>();
  var listSessionsCalls = 0;

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield const CompletedText('First reply');
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) {
    if (sessionId == 'second') {
      return Future.value(const [
        ChatMessage(
          role: 'assistant',
          text: 'Second history',
          persistedId: '4',
        ),
      ]);
    }
    if (!finalRefreshStarted.isCompleted) finalRefreshStarted.complete();
    return releaseFinalRefresh.future;
  }

  @override
  Future<List<HermesSession>> listSessions() async {
    listSessionsCalls += 1;
    return const [HermesSession(id: 'first', title: 'First')];
  }

  @override
  void close() {}
}

class _SendOwnershipApi extends HermesApi {
  _SendOwnershipApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final firstStreamStarted = Completer<void>();
  final releaseFirstStream = Completer<void>();
  final secondStreamStarted = Completer<void>();
  final releaseSecondStream = Completer<void>();
  final sentSessions = <String>[];

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    sentSessions.add(sessionId);
    if (sessionId == 'first') {
      firstStreamStarted.complete();
      await releaseFirstStream.future;
      yield const CompletedText('Late first reply');
    } else {
      secondStreamStarted.complete();
      await releaseSecondStream.future;
      yield const CompletedText('Second reply');
    }
  }

  @override
  Future<List<ChatMessage>> messages(
    String sessionId,
  ) async => switch (sessionId) {
    'first' => const [],
    _ => const [
      ChatMessage(role: 'assistant', text: 'Second history', persistedId: '1'),
      ChatMessage(role: 'user', text: 'Question for second', persistedId: '2'),
      ChatMessage(role: 'assistant', text: 'Second reply', persistedId: '3'),
    ],
  };

  @override
  Future<List<HermesSession>> listSessions() async => const [
    HermesSession(id: 'first', title: 'First'),
    HermesSession(id: 'second', title: 'Second'),
  ];

  @override
  void close() {}
}

class _ApprovalDuringSwitchApi extends HermesApi {
  _ApprovalDuringSwitchApi()
    : super(
        const ConnectionConfig(baseUrl: 'https://example.test', token: 'x'),
      );

  final approvalEmitted = Completer<void>();
  final releaseStream = Completer<void>();
  final approvalResponseStarted = Completer<void>();
  final releaseApprovalResponse = Completer<void>();
  final approvalChoices = <String>[];

  @override
  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    yield const ApprovalUpdate(
      ApprovalRequest(
        sessionId: 'runtime-first',
        command: 'sudo true',
        description: 'Run command',
        allowPermanent: true,
      ),
    );
    approvalEmitted.complete();
    await releaseStream.future;
  }

  @override
  Future<void> respondApproval(ApprovalRequest request, String choice) async {
    approvalChoices.add(choice);
    approvalResponseStarted.complete();
    await releaseApprovalResponse.future;
  }

  @override
  Future<List<ChatMessage>> messages(String sessionId) async => const [];

  @override
  void close() {}
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
