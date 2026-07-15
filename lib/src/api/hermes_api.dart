import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../connection.dart';
import '../models.dart';
import 'sse_parser.dart';

sealed class StreamUpdate {
  const StreamUpdate();
}

class TextDelta extends StreamUpdate {
  const TextDelta(this.text);
  final String text;
}

class ToolUpdate extends StreamUpdate {
  const ToolUpdate(this.event);
  final ChatEvent event;
}

class HermesApi {
  HermesApi(this.config, {http.Client? client})
    : _client = client ?? http.Client();

  final ConnectionConfig config;
  final http.Client _client;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${config.token}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Uri _uri(String path) => Uri.parse('${config.normalizedBaseUrl}$path');

  Future<void> checkHealth() async {
    final response = await _client
        .get(_uri('/v1/capabilities'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    _ensureSuccess(response);
  }

  Future<List<HermesSession>> listSessions() async {
    final response = await _client.get(
      _uri('/api/sessions'),
      headers: _headers,
    );
    _ensureSuccess(response);
    final decoded = jsonDecode(response.body);
    final raw = decoded is List
        ? decoded
        : (decoded['sessions'] ?? decoded['items'] ?? const []);
    return (raw as List)
        .whereType<Map>()
        .map((item) => HermesSession.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<HermesSession> createSession({String? title}) async {
    final response = await _client.post(
      _uri('/api/sessions'),
      headers: _headers,
      body: jsonEncode(title == null ? <String, String>{} : {'title': title}),
    );
    _ensureSuccess(response);
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return HermesSession.fromJson(
      (decoded['session'] as Map?)?.cast<String, dynamic>() ?? decoded,
    );
  }

  Future<List<ChatMessage>> messages(String sessionId) async {
    final response = await _client.get(
      _uri('/api/sessions/${Uri.encodeComponent(sessionId)}/messages'),
      headers: _headers,
    );
    _ensureSuccess(response);
    final decoded = jsonDecode(response.body);
    final raw = decoded is List ? decoded : (decoded['messages'] ?? const []);
    return (raw as List)
        .whereType<Map>()
        .map((item) => ChatMessage.fromJson(item.cast<String, dynamic>()))
        .where((message) => message.text.isNotEmpty)
        .toList(growable: false);
  }

  Stream<StreamUpdate> chat(String sessionId, String input) async* {
    final request =
        http.Request(
            'POST',
            _uri('/api/sessions/${Uri.encodeComponent(sessionId)}/chat/stream'),
          )
          ..headers.addAll({..._headers, 'Accept': 'text/event-stream'})
          ..body = jsonEncode({'input': input});
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw HermesApiException(response.statusCode, body);
    }

    var buffer = '';
    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer += chunk.replaceAll('\r\n', '\n');
      var boundary = buffer.indexOf('\n\n');
      while (boundary >= 0) {
        final block = buffer.substring(0, boundary + 2);
        buffer = buffer.substring(boundary + 2);
        for (final event in SseParser.parse(block)) {
          final update = _toUpdate(event);
          if (update != null) yield update;
        }
        boundary = buffer.indexOf('\n\n');
      }
    }
    if (buffer.trim().isNotEmpty) {
      for (final event in SseParser.parse('$buffer\n\n')) {
        final update = _toUpdate(event);
        if (update != null) yield update;
      }
    }
  }

  StreamUpdate? _toUpdate(SseEvent event) {
    dynamic payload;
    try {
      payload = jsonDecode(event.data);
    } on FormatException {
      payload = event.data;
    }
    if (event.type == 'assistant.delta' ||
        event.type == 'response.output_text.delta') {
      if (payload is String) return TextDelta(payload);
      if (payload is Map) {
        final text = payload['delta'] ?? payload['text'] ?? payload['content'];
        if (text != null) return TextDelta(text.toString());
      }
    }
    if (event.type.startsWith('tool.') ||
        event.type == 'response.output_item.added' ||
        event.type == 'response.output_item.done') {
      final map = payload is Map<String, dynamic>
          ? payload
          : <String, dynamic>{'data': payload};
      return ToolUpdate(ChatEvent.tool(type: event.type, payload: map));
    }
    if (event.type == 'run.completed' && payload is Map) {
      final output = payload['output'];
      if (output is String && output.isNotEmpty) return TextDelta(output);
    }
    return null;
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HermesApiException(response.statusCode, response.body);
    }
  }

  void close() => _client.close();
}

class HermesApiException implements Exception {
  const HermesApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;

  @override
  String toString() => 'Hermes API returned $statusCode: $body';
}
