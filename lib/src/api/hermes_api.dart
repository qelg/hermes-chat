import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../connection.dart';
import '../models.dart';

sealed class StreamUpdate {
  const StreamUpdate();
}

class TextDelta extends StreamUpdate {
  const TextDelta(this.text);
  final String text;
}

class CompletedText extends StreamUpdate {
  const CompletedText(this.text);
  final String text;
}

class ToolUpdate extends StreamUpdate {
  const ToolUpdate(this.event);
  final ChatEvent event;
}

class ApprovalUpdate extends StreamUpdate {
  const ApprovalUpdate(this.request);
  final ApprovalRequest request;
}

class ApprovalRequest {
  const ApprovalRequest({
    required this.sessionId,
    required this.command,
    required this.description,
    required this.allowPermanent,
  });

  final String sessionId;
  final String command;
  final String description;
  final bool allowPermanent;
}

class GatewayEvent {
  const GatewayEvent({
    required this.type,
    this.sessionId,
    required this.payload,
  });

  final String type;
  final String? sessionId;
  final Map<String, dynamic> payload;
}

abstract class HermesTransport {
  Stream<GatewayEvent> get events;
  Future<void> connect();
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]);
  Future<String> transcribeAudio(String path);
  Future<void> close();
}

class HermesApi {
  HermesApi(this.config, {HermesTransport? transport})
    : _transport = transport ?? HermesServeTransport(config);

  final ConnectionConfig config;
  final HermesTransport _transport;
  final Map<String, String> _runtimeSessions = {};
  final Set<String> _freshSessions = {};

  Future<void> checkHealth() => _transport.connect();

  Future<List<HermesSession>> listSessions() async {
    final result = await _transport.request('session.list', {'limit': 200});
    final raw = result['sessions'] as List? ?? const [];
    return raw
        .whereType<Map>()
        .map((item) => HermesSession.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<HermesSession> createSession({String? title}) async {
    final result = await _transport.request('session.create', {
      'cols': 96,
      'source': 'mobile',
      if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
    });
    final runtimeId = result['session_id']?.toString() ?? '';
    final storedId = result['stored_session_id']?.toString() ?? runtimeId;
    if (runtimeId.isEmpty || storedId.isEmpty) {
      throw const HermesStreamException('Hermes returned no session ID');
    }
    _runtimeSessions[storedId] = runtimeId;
    _freshSessions.add(storedId);
    return HermesSession(
      id: storedId,
      title: title?.trim().isNotEmpty == true
          ? title!.trim()
          : 'Untitled session',
    );
  }

  Future<List<ChatMessage>> messages(String sessionId) async {
    if (_freshSessions.remove(sessionId)) return const [];
    final result = await _resume(sessionId);
    return _messagesFromResult(result);
  }

  Future<Map<String, dynamic>> _resume(String storedId) async {
    final result = await _transport.request('session.resume', {
      'session_id': storedId,
      'cols': 96,
      'source': 'mobile',
    });
    final runtimeId = result['session_id']?.toString() ?? '';
    if (runtimeId.isEmpty) {
      throw const HermesStreamException(
        'Hermes returned no runtime session ID',
      );
    }
    _runtimeSessions[storedId] = runtimeId;
    return result;
  }

  List<ChatMessage> _messagesFromResult(Map<String, dynamic> result) {
    final raw = result['messages'] as List? ?? const [];
    return raw
        .whereType<Map>()
        .expand(
          (item) => ChatMessage.fromJsonMany(item.cast<String, dynamic>()),
        )
        .toList(growable: false);
  }

  Future<String> transcribeAudio(String path) =>
      _transport.transcribeAudio(path);

  Stream<StreamUpdate> chat(String storedId, String input) async* {
    var runtimeId = _runtimeSessions[storedId];
    runtimeId ??= (await _resume(storedId))['session_id']?.toString();
    if (runtimeId == null || runtimeId.isEmpty) {
      throw const HermesStreamException('Session is not connected');
    }

    final incoming = StreamController<GatewayEvent>();
    final subscription = _transport.events
        .where(
          (event) => event.sessionId == null || event.sessionId == runtimeId,
        )
        .listen(incoming.add, onError: incoming.addError);

    try {
      await _transport.request('prompt.submit', {
        'session_id': runtimeId,
        'text': input,
      });
      await for (final event in incoming.stream) {
        final update = _toUpdate(event, runtimeId);
        if (update != null) yield update;
        if (event.type == 'message.complete') break;
        if (event.type == 'error') {
          final message = event.payload['message']?.toString();
          throw HermesStreamException(
            message == null || message.isEmpty
                ? 'Unknown Hermes error'
                : message,
          );
        }
      }
    } finally {
      await subscription.cancel();
      await incoming.close();
    }
  }

  StreamUpdate? _toUpdate(GatewayEvent event, String runtimeId) {
    switch (event.type) {
      case 'message.delta':
        final text = event.payload['text']?.toString() ?? '';
        return text.isEmpty ? null : TextDelta(text);
      case 'message.complete':
        final text =
            (event.payload['text'] ?? event.payload['content'])?.toString() ??
            '';
        return CompletedText(text);
      case 'tool.start':
      case 'tool.complete':
        final type = event.type == 'tool.start'
            ? 'tool.started'
            : 'tool.completed';
        return ToolUpdate(ChatEvent.tool(type: type, payload: event.payload));
      case 'approval.request':
        return ApprovalUpdate(
          ApprovalRequest(
            sessionId: runtimeId,
            command: event.payload['command']?.toString() ?? '',
            description: event.payload['description']?.toString() ?? '',
            allowPermanent: event.payload['allow_permanent'] == true,
          ),
        );
      default:
        return null;
    }
  }

  Future<void> respondApproval(ApprovalRequest request, String choice) async {
    await _transport.request('approval.respond', {
      'session_id': request.sessionId,
      'choice': choice,
    });
  }

  Future<void> interrupt(String storedId) async {
    final runtimeId = _runtimeSessions[storedId];
    if (runtimeId == null) return;
    await _transport.request('session.interrupt', {'session_id': runtimeId});
  }

  void close() {
    unawaited(_transport.close());
  }
}

class HermesServeTransport implements HermesTransport {
  HermesServeTransport(this.config, {HttpClient? httpClient})
    : _http = httpClient ?? HttpClient();

  final ConnectionConfig config;
  final HttpClient _http;
  final Map<String, Cookie> _cookies = {};
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  int _nextRequestId = 0;

  @override
  Stream<GatewayEvent> get events => _events.stream;

  Uri _uri(String path) => Uri.parse('${config.normalizedBaseUrl}$path');

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    String query;
    if (config.token.isNotEmpty) {
      query = 'token=${Uri.encodeQueryComponent(config.token)}';
    } else {
      await _login();
      final ticket = await _jsonRequest('POST', '/api/auth/ws-ticket');
      final value = ticket['ticket']?.toString() ?? '';
      if (value.isEmpty) {
        throw const HermesStreamException(
          'Hermes returned no WebSocket ticket',
        );
      }
      query = 'ticket=${Uri.encodeQueryComponent(value)}';
    }

    final base = _uri('/api/ws');
    final wsUri = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      query: query,
    );
    final socket = await WebSocket.connect(
      wsUri.toString(),
    ).timeout(const Duration(seconds: 15));
    _socket = socket;
    _socketSubscription = socket.listen(
      _handleFrame,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
      cancelOnError: false,
    );
  }

  Future<void> _login() async {
    if (config.username.isEmpty || config.password.isEmpty) {
      throw const HermesStreamException('Username and password are required');
    }
    await _jsonRequest(
      'POST',
      '/auth/password-login',
      body: {
        'provider': 'basic',
        'username': config.username,
        'password': config.password,
        'next': '',
      },
    );
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final request = await _http.openUrl(method, _uri(path));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
    }
    if (config.token.isNotEmpty) {
      request.headers.set('X-Hermes-Session-Token', config.token);
    }
    if (_cookies.isNotEmpty) {
      request.headers.set(
        HttpHeaders.cookieHeader,
        _cookies.values
            .map((cookie) => '${cookie.name}=${cookie.value}')
            .join('; '),
      );
    }
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 20));
    for (final cookie in response.cookies) {
      _cookies[cookie.name] = cookie;
    }
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HermesApiException(response.statusCode, text);
    }
    if (text.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : <String, dynamic>{'data': decoded};
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    await connect();
    final socket = _socket;
    if (socket == null) {
      throw const HermesStreamException('Hermes WebSocket is disconnected');
    }
    final id = 'mobile-${++_nextRequestId}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    try {
      return await completer.future.timeout(const Duration(minutes: 30));
    } finally {
      _pending.remove(id);
    }
  }

  void _handleFrame(dynamic frame) {
    if (frame is! String) return;
    final decoded = jsonDecode(frame);
    if (decoded is! Map) return;
    final message = decoded.cast<String, dynamic>();
    final id = message['id']?.toString();
    if (id != null && _pending.containsKey(id)) {
      final completer = _pending[id]!;
      final error = message['error'];
      if (error is Map) {
        completer.completeError(
          HermesStreamException(
            error['message']?.toString() ?? 'JSON-RPC error',
          ),
        );
      } else {
        final result = message['result'];
        completer.complete(
          result is Map
              ? result.cast<String, dynamic>()
              : <String, dynamic>{'data': result},
        );
      }
      return;
    }
    if (message['method'] != 'event') return;
    final params = message['params'];
    if (params is! Map) return;
    final event = params.cast<String, dynamic>();
    final payload = event['payload'];
    _events.add(
      GatewayEvent(
        type: event['type']?.toString() ?? '',
        sessionId: event['session_id']?.toString(),
        payload: payload is Map
            ? payload.cast<String, dynamic>()
            : <String, dynamic>{'data': payload},
      ),
    );
  }

  void _handleSocketError(Object error) {
    final wrapped = HermesStreamException('Hermes WebSocket failed: $error');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(wrapped);
    }
    _events.addError(wrapped);
  }

  void _handleSocketDone() {
    _socket = null;
    _handleSocketError(
      const HermesStreamException('Hermes WebSocket disconnected'),
    );
  }

  @override
  Future<String> transcribeAudio(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final extension = file.uri.pathSegments.last.split('.').last.toLowerCase();
    final mimeType = switch (extension) {
      'm4a' || 'aac' => 'audio/mp4',
      'ogg' => 'audio/ogg',
      'webm' => 'audio/webm',
      'wav' => 'audio/wav',
      _ => 'application/octet-stream',
    };
    final response = await _jsonRequest(
      'POST',
      '/api/audio/transcribe',
      body: {
        'data_url': 'data:$mimeType;base64,${base64Encode(bytes)}',
        'mime_type': mimeType,
      },
    );
    final transcript = response['transcript']?.toString().trim() ?? '';
    if (transcript.isEmpty) {
      throw const HermesStreamException('Transcription returned no text');
    }
    return transcript;
  }

  @override
  Future<void> close() async {
    await _socketSubscription?.cancel();
    await _socket?.close();
    _socket = null;
    _http.close(force: true);
    if (!_events.isClosed) await _events.close();
  }
}

class HermesApiException implements Exception {
  const HermesApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'Hermes returned $statusCode: $body';
}

class HermesStreamException implements Exception {
  const HermesStreamException(this.message);
  final String message;

  @override
  String toString() => 'Hermes connection failed: $message';
}
