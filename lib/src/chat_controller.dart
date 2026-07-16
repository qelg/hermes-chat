import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/hermes_api.dart';
import 'models.dart';

class ChatController extends ChangeNotifier {
  ChatController(
    this.api, {
    Duration Function()? elapsed,
    this.refreshInterval = const Duration(seconds: 2),
  }) : _elapsed = elapsed ?? _startClock() {
    _reconnectionSubscription = api.reconnections.listen(
      (_) => unawaited(refreshHistory()),
    );
  }

  static Duration Function() _startClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final HermesApi api;
  final Duration Function() _elapsed;
  final Duration refreshInterval;
  Timer? _refreshTimer;
  bool _refreshing = false;
  bool _refreshQueued = false;
  bool _disposed = false;
  int _timelineRevision = 0;
  late final StreamSubscription<void> _reconnectionSubscription;
  List<ChatMessage> _pendingPersistence = const [];
  List<HermesSession> sessions = const [];
  List<ChatMessage> messages = const [];
  HermesSession? selected;
  bool loading = false;
  bool sending = false;
  bool transcribing = false;
  String? voiceError;
  ApprovalRequest? pendingApproval;
  String? error;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> loadSessions() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      sessions = await api.listSessions();
      if (selected != null) {
        selected = sessions.where((s) => s.id == selected!.id).firstOrNull;
      }
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<HermesSession?> createSession() async {
    try {
      final session = await api.createSession();
      sessions = [session, ...sessions];
      await select(session);
      return session;
    } catch (exception) {
      error = exception.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> select(HermesSession session) async {
    _refreshTimer?.cancel();
    _pendingPersistence = const [];
    _timelineRevision++;
    final revision = _timelineRevision;
    selected = session;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final loaded = await api.messages(session.id);
      if (!_disposed &&
          revision == _timelineRevision &&
          selected?.id == session.id) {
        messages = loaded;
      }
    } catch (exception) {
      if (!_disposed && revision == _timelineRevision) {
        error = exception.toString();
      }
    } finally {
      if (!_disposed &&
          revision == _timelineRevision &&
          selected?.id == session.id) {
        loading = false;
        notifyListeners();
        _refreshTimer = Timer.periodic(
          refreshInterval,
          (_) => unawaited(refreshHistory()),
        );
      }
    }
  }

  Future<void> refreshHistory({bool force = false}) async {
    final session = selected;
    if (_disposed || session == null || (sending && !force)) return;
    if (_refreshing) {
      if (force) _refreshQueued = true;
      return;
    }
    final revision = _timelineRevision;
    _refreshing = true;
    try {
      final canonical = await api.messages(session.id);
      if (_disposed ||
          selected?.id != session.id ||
          revision != _timelineRevision ||
          (sending && !force)) {
        return;
      }
      messages = _reconcileCanonical(canonical);
      notifyListeners();
    } catch (_) {
      // Periodic reconciliation is best-effort and retries on the next tick.
    } finally {
      _refreshing = false;
      if (_refreshQueued && !_disposed) {
        _refreshQueued = false;
        unawaited(refreshHistory(force: true));
      }
    }
  }

  List<ChatMessage> _reconcileCanonical(List<ChatMessage> canonical) {
    if (_pendingPersistence.isEmpty) return canonical;

    final previouslyPersisted = messages
        .map((message) => message.persistedId)
        .whereType<String>()
        .toSet();
    final newlyPersisted = canonical
        .where(
          (message) =>
              message.persistedId != null &&
              !previouslyPersisted.contains(message.persistedId),
        )
        .toList();
    final stillPending = <ChatMessage>[];
    for (final pending in _pendingPersistence) {
      final match = newlyPersisted.indexWhere(
        (persisted) => _samePersistedMessage(pending, persisted),
      );
      if (match >= 0) {
        newlyPersisted.removeAt(match);
      } else {
        stillPending.add(pending);
      }
    }
    _pendingPersistence = stillPending;
    return [...canonical, ...stillPending];
  }

  bool _samePersistedMessage(ChatMessage pending, ChatMessage persisted) {
    final pendingEvent = pending.event;
    final persistedEvent = persisted.event;
    if (pendingEvent != null || persistedEvent != null) {
      return pendingEvent?.toolCallId != null &&
          pendingEvent?.toolCallId == persistedEvent?.toolCallId &&
          pendingEvent?.toolState == persistedEvent?.toolState;
    }
    return pending.role == persisted.role && pending.text == persisted.text;
  }

  Future<bool> sendVoice(String path) async {
    if (sending || transcribing) return false;
    transcribing = true;
    voiceError = null;
    notifyListeners();
    try {
      final transcript = await api.transcribeAudio(path);
      transcribing = false;
      notifyListeners();
      await send(transcript);
      return true;
    } catch (exception) {
      transcribing = false;
      voiceError = exception.toString();
      notifyListeners();
      return false;
    }
  }

  void dismissVoiceError() {
    voiceError = null;
    notifyListeners();
  }

  Future<void> send(String text) async {
    final session = selected;
    final clean = text.trim();
    if (session == null || clean.isEmpty || sending) return;
    _timelineRevision++;
    messages = [...messages, ChatMessage(role: 'user', text: clean)];
    sending = true;
    error = null;
    var response = '';
    var generationElapsed = Duration.zero;
    var generationStartedAt = _elapsed();
    var generationRunning = true;
    Duration? generationDuration;
    var receivedTool = false;
    var completed = false;
    final toolStarts = <String, Duration>{};

    Duration currentGenerationDuration(Duration now) =>
        generationElapsed +
        (generationRunning ? now - generationStartedAt : Duration.zero);

    void pauseGeneration(Duration now) {
      if (!generationRunning) return;
      generationElapsed += now - generationStartedAt;
      generationRunning = false;
    }

    void resumeGeneration(Duration now) {
      if (generationRunning || toolStarts.isNotEmpty) return;
      generationStartedAt = now;
      generationRunning = true;
    }

    void finishPendingTools(String state) {
      final finishedAt = _elapsed();
      final terminalMessages = toolStarts.entries.map((entry) {
        final startedEvent = messages
            .map((message) => message.event)
            .whereType<ChatEvent>()
            .lastWhere(
              (event) =>
                  event.toolCallId == entry.key && event.toolState == 'started',
            );
        return ChatMessage.tool(
          startedEvent.withDuration(finishedAt - entry.value, state: state),
        );
      });
      messages = [...messages, ...terminalMessages];
      toolStarts.clear();
    }

    notifyListeners();
    try {
      await for (final update in api.chat(session.id, clean)) {
        switch (update) {
          case HistoryUpdate(:final messages):
            this.messages = [
              ...messages,
              ChatMessage(role: 'user', text: clean),
            ];
          case TextDelta(:final text):
            final now = _elapsed();
            if (!generationRunning && toolStarts.isEmpty) {
              generationStartedAt = now;
              generationRunning = true;
            }
            response += text;
            final withoutDraft = messages
                .where((m) => m.role != '_draft')
                .toList();
            messages = [
              ...withoutDraft,
              ChatMessage(
                role: '_draft',
                text: response,
                duration: currentGenerationDuration(now),
              ),
            ];
          case CompletedText(:final text):
            completed = true;
            final completedAt = _elapsed();
            generationDuration = currentGenerationDuration(completedAt);
            if (text.isNotEmpty) response = text;
            final withoutDraft = messages
                .where((m) => m.role != '_draft')
                .toList();
            messages = [
              ...withoutDraft,
              if (response.isNotEmpty)
                ChatMessage(
                  role: '_draft',
                  text: response,
                  duration: generationDuration,
                ),
            ];
          case ToolUpdate(:final event):
            receivedTool = true;
            final id = event.toolCallId;
            var timedEvent = event;
            if (id != null && event.toolState == 'started') {
              final startedAt = _elapsed();
              pauseGeneration(startedAt);
              toolStarts.putIfAbsent(id, () => startedAt);
            } else if (id != null &&
                const {
                  'completed',
                  'failed',
                  'cancelled',
                }.contains(event.toolState)) {
              final completedAt = _elapsed();
              final started = toolStarts.remove(id);
              if (started != null) {
                timedEvent = event.withDuration(completedAt - started);
              }
              if (toolStarts.isEmpty) resumeGeneration(completedAt);
            }
            messages = [...messages, ChatMessage.tool(timedEvent)];
          case ApprovalUpdate(:final request):
            pendingApproval = request;
        }
        notifyListeners();
      }
      if (toolStarts.isNotEmpty) finishPendingTools('cancelled');
      if (response.isNotEmpty) {
        messages = [
          ...messages.where((m) => m.role != '_draft'),
          ChatMessage(
            role: 'assistant',
            text: response,
            duration:
                generationDuration ?? currentGenerationDuration(_elapsed()),
          ),
        ];
      } else if (!receivedTool) {
        messages = await api.messages(session.id);
      }
      if (completed) {
        _pendingPersistence = messages
            .where(
              (message) =>
                  message.persistedId == null && message.role != '_draft',
            )
            .toList(growable: false);
        await refreshHistory(force: true);
      }
      await loadSessions();
    } catch (exception) {
      finishPendingTools('failed');
      final withoutDraft = messages.where((m) => m.role != '_draft').toList();
      messages = [
        ...withoutDraft,
        if (response.isNotEmpty)
          ChatMessage(
            role: 'assistant',
            text: response,
            duration: currentGenerationDuration(_elapsed()),
          ),
      ];
      error = exception.toString();
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<void> respondApproval(String choice) async {
    final request = pendingApproval;
    if (request == null) return;
    try {
      await api.respondApproval(request, choice);
      pendingApproval = null;
    } catch (exception) {
      error = exception.toString();
    }
    notifyListeners();
  }

  Future<void> interrupt() async {
    final session = selected;
    if (session == null || !sending) return;
    try {
      await api.interrupt(session.id);
    } catch (exception) {
      error = exception.toString();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    unawaited(_reconnectionSubscription.cancel());
    api.close();
    super.dispose();
  }
}
