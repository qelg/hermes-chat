import 'package:flutter/foundation.dart';

import 'api/hermes_api.dart';
import 'models.dart';

class ChatController extends ChangeNotifier {
  ChatController(this.api);

  final HermesApi api;
  List<HermesSession> sessions = const [];
  List<ChatMessage> messages = const [];
  List<ChatEvent> events = const [];
  HermesSession? selected;
  bool loading = false;
  bool sending = false;
  String? error;

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

  Future<void> createSession() async {
    try {
      final session = await api.createSession();
      sessions = [session, ...sessions];
      await select(session);
    } catch (exception) {
      error = exception.toString();
      notifyListeners();
    }
  }

  Future<void> select(HermesSession session) async {
    selected = session;
    loading = true;
    error = null;
    events = const [];
    notifyListeners();
    try {
      messages = await api.messages(session.id);
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> send(String text) async {
    final session = selected;
    final clean = text.trim();
    if (session == null || clean.isEmpty || sending) return;
    messages = [...messages, ChatMessage(role: 'user', text: clean)];
    events = const [];
    sending = true;
    error = null;
    var response = '';
    notifyListeners();
    try {
      await for (final update in api.chat(session.id, clean)) {
        switch (update) {
          case TextDelta(:final text):
            response += text;
            final withoutDraft = messages
                .where((m) => m.role != '_draft')
                .toList();
            messages = [
              ...withoutDraft,
              ChatMessage(role: '_draft', text: response),
            ];
          case CompletedText(:final text):
            response = text;
            final withoutDraft = messages
                .where((m) => m.role != '_draft')
                .toList();
            messages = [
              ...withoutDraft,
              ChatMessage(role: '_draft', text: response),
            ];
          case ToolUpdate(:final event):
            events = [...events, event];
        }
        notifyListeners();
      }
      if (response.isNotEmpty) {
        messages = [
          ...messages.where((m) => m.role != '_draft'),
          ChatMessage(role: 'assistant', text: response),
        ];
      } else {
        messages = await api.messages(session.id);
      }
      await loadSessions();
    } catch (exception) {
      messages = messages.where((m) => m.role != '_draft').toList();
      error = exception.toString();
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}
