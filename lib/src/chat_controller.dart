import 'package:flutter/foundation.dart';

import 'api/hermes_api.dart';
import 'models.dart';

class ChatController extends ChangeNotifier {
  ChatController(this.api);

  final HermesApi api;
  List<HermesSession> sessions = const [];
  List<ChatMessage> messages = const [];
  HermesSession? selected;
  bool loading = false;
  bool sending = false;
  bool transcribing = false;
  String? voiceError;
  ApprovalRequest? pendingApproval;
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
    selected = session;
    loading = true;
    error = null;
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
    messages = [...messages, ChatMessage(role: 'user', text: clean)];
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
            if (text.isNotEmpty) response = text;
            final withoutDraft = messages
                .where((m) => m.role != '_draft')
                .toList();
            messages = [
              ...withoutDraft,
              if (response.isNotEmpty)
                ChatMessage(role: '_draft', text: response),
            ];
          case ToolUpdate(:final event):
            messages = [...messages, ChatMessage.tool(event)];
          case ApprovalUpdate(:final request):
            pendingApproval = request;
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
    api.close();
    super.dispose();
  }
}
