import 'dart:convert';

class HermesSession {
  const HermesSession({
    required this.id,
    required this.title,
    this.updatedAt,
    this.source,
  });

  final String id;
  final String title;
  final DateTime? updatedAt;
  final String? source;

  factory HermesSession.fromJson(Map<String, dynamic> json) {
    final rawDate =
        json['updated_at'] ?? json['last_active_at'] ?? json['created_at'];
    return HermesSession(
      id: (json['id'] ?? json['session_id']).toString(),
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : 'Untitled session',
      updatedAt: rawDate is String ? DateTime.tryParse(rawDate) : null,
      source: json['source'] as String?,
    );
  }
}

class ChatEvent {
  const ChatEvent._({
    required this.kind,
    required this.summary,
    required this.details,
  });

  final ChatEventKind kind;
  final String summary;
  final String details;

  factory ChatEvent.tool({
    required String type,
    required Map<String, dynamic> payload,
  }) {
    final name =
        payload['name'] ?? payload['tool'] ?? payload['tool_name'] ?? 'tool';
    final state = type.split('.').last;
    return ChatEvent._(
      kind: ChatEventKind.tool,
      summary: '$name · $state',
      details: const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  factory ChatEvent.status(String text) =>
      ChatEvent._(kind: ChatEventKind.status, summary: text, details: text);
}

enum ChatEventKind { tool, status }

class ChatMessage {
  const ChatMessage({required this.role, required this.text, this.event});

  factory ChatMessage.tool(ChatEvent event) =>
      ChatMessage(role: '_tool', text: '', event: event);

  final String role;
  final String text;
  final ChatEvent? event;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final role = (json['role'] ?? 'assistant').toString();
    final raw = json['content'] ?? json['text'] ?? '';
    String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List) {
      text = raw
          .whereType<Map>()
          .map((part) => part['text']?.toString() ?? '')
          .where((part) => part.isNotEmpty)
          .join('\n');
    } else {
      text = raw.toString();
    }
    return ChatMessage(role: role, text: text);
  }

  static List<ChatMessage> fromJsonMany(Map<String, dynamic> json) {
    final role = (json['role'] ?? 'assistant').toString();
    if (role == 'tool') {
      return [
        ChatMessage.tool(
          ChatEvent.tool(
            type: 'tool.completed',
            payload: {
              'tool_call_id': json['tool_call_id'],
              'tool_name': json['tool_name'] ?? json['name'] ?? 'tool',
              'result': json['content'] ?? json['text'] ?? '',
            },
          ),
        ),
      ];
    }

    final result = <ChatMessage>[];
    final message = ChatMessage.fromJson(json);
    if (message.text.isNotEmpty) result.add(message);

    final toolCalls = json['tool_calls'];
    if (toolCalls is List) {
      for (final rawCall in toolCalls.whereType<Map>()) {
        final call = rawCall.cast<String, dynamic>();
        final function = call['function'] is Map
            ? (call['function'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        dynamic arguments = function['arguments'] ?? call['arguments'];
        if (arguments is String) {
          try {
            arguments = jsonDecode(arguments);
          } on FormatException {
            // Preserve non-JSON arguments as text in the expandable details.
          }
        }
        result.add(
          ChatMessage.tool(
            ChatEvent.tool(
              type: 'tool.started',
              payload: {
                'tool_call_id': call['id'],
                'tool_name': function['name'] ?? call['name'] ?? 'tool',
                'args': arguments,
              },
            ),
          ),
        );
      }
    }
    return result;
  }
}
