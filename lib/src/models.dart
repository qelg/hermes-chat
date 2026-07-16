import 'dart:convert';

class HermesSession {
  const HermesSession({
    required this.id,
    required this.title,
    this.updatedAt,
    this.source,
    this.preview,
  });

  final String id;
  final String title;
  final DateTime? updatedAt;
  final String? source;
  final String? preview;

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
      preview: json['preview']?.toString(),
    );
  }
}

List<HermesSession> filterSessions(List<HermesSession> sessions, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return sessions;
  return sessions
      .where(
        (session) =>
            session.title.toLowerCase().contains(needle) ||
            (session.preview?.toLowerCase().contains(needle) ?? false),
      )
      .toList(growable: false);
}

class ChatEvent {
  const ChatEvent._({
    required this.kind,
    required this.summary,
    required this.details,
    this.toolName,
    this.toolState,
    this.toolCallId,
  });

  final ChatEventKind kind;
  final String summary;
  final String details;
  final String? toolName;
  final String? toolState;
  final String? toolCallId;

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
      toolName: name.toString(),
      toolState: state,
      toolCallId:
          (payload['tool_call_id'] ?? payload['call_id'] ?? payload['id'])
              ?.toString(),
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

sealed class TimelineBlock {
  const TimelineBlock();
}

class MessageTimelineBlock extends TimelineBlock {
  const MessageTimelineBlock(this.message);
  final ChatMessage message;
}

List<ChatEvent> _representativeToolCalls(List<ChatEvent> events) {
  final started = events
      .where((event) => event.toolState == 'started')
      .toList();
  final candidates = started.isNotEmpty
      ? started
      : events.where((event) => event.toolState == 'completed').toList();
  final seenIds = <String>{};
  return candidates
      .where((event) {
        final id = event.toolCallId;
        return id == null || seenIds.add(id);
      })
      .toList(growable: false);
}

class ToolGroupTimelineBlock extends TimelineBlock {
  ToolGroupTimelineBlock(this.events) {
    final calls = _representativeToolCalls(events);
    callCount = calls.length;
    counts = Map.unmodifiable(
      calls.fold(<String, int>{}, (result, event) {
        final name = event.toolName ?? 'tool';
        result[name] = (result[name] ?? 0) + 1;
        return result;
      }),
    );
  }

  final List<ChatEvent> events;
  late final int callCount;
  late final Map<String, int> counts;
}

List<TimelineBlock> groupTimeline(
  List<ChatMessage> messages, {
  int minimumGroupSize = 4,
}) {
  final blocks = <TimelineBlock>[];
  final tools = <ChatEvent>[];

  void flushTools() {
    if (_representativeToolCalls(tools).length >= minimumGroupSize) {
      blocks.add(ToolGroupTimelineBlock(List.unmodifiable(tools)));
    } else {
      blocks.addAll(
        tools.map((event) => MessageTimelineBlock(ChatMessage.tool(event))),
      );
    }
    tools.clear();
  }

  for (final message in messages) {
    if (message.event case final event?) {
      tools.add(event);
    } else {
      flushTools();
      blocks.add(MessageTimelineBlock(message));
    }
  }
  flushTools();
  return blocks;
}
