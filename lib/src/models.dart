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
    this.duration,
  });

  final ChatEventKind kind;
  final String summary;
  final String details;
  final String? toolName;
  final String? toolState;
  final String? toolCallId;
  final Duration? duration;

  factory ChatEvent.tool({
    required String type,
    required Map<String, dynamic> payload,
  }) {
    final name =
        payload['name'] ?? payload['tool'] ?? payload['tool_name'] ?? 'tool';
    final state = type.split('.').last;
    final rawDuration = payload['duration_ms'];
    final duration = rawDuration is num
        ? Duration(microseconds: (rawDuration * 1000).round())
        : null;
    final durationLabel = duration == null
        ? ''
        : ' · ${formatElapsed(duration)}';
    return ChatEvent._(
      kind: ChatEventKind.tool,
      summary: '$name · $state$durationLabel',
      details: const JsonEncoder.withIndent('  ').convert(payload),
      toolName: name.toString(),
      toolState: state,
      toolCallId:
          (payload['tool_call_id'] ??
                  payload['tool_id'] ??
                  payload['call_id'] ??
                  payload['id'])
              ?.toString(),
      duration: duration,
    );
  }

  ChatEvent withDuration(Duration value, {String? state}) {
    final resolvedState = state ?? toolState ?? 'completed';
    final durationLabel = formatElapsed(value);
    return ChatEvent._(
      kind: kind,
      summary: '${toolName ?? 'tool'} · $resolvedState · $durationLabel',
      details: details,
      toolName: toolName,
      toolState: resolvedState,
      toolCallId: toolCallId,
      duration: value,
    );
  }

  factory ChatEvent.status(String text) =>
      ChatEvent._(kind: ChatEventKind.status, summary: text, details: text);
}

String formatElapsed(Duration value) =>
    '${(value.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(1)} s';

enum ChatEventKind { tool, status }

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.event,
    this.duration,
    this.persistedId,
  });

  factory ChatMessage.tool(ChatEvent event, {String? persistedId}) =>
      ChatMessage(
        role: '_tool',
        text: '',
        event: event,
        persistedId: persistedId,
      );

  final String role;
  final String text;
  final ChatEvent? event;
  final Duration? duration;
  final String? persistedId;

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
    return ChatMessage(
      role: role,
      text: text,
      persistedId: json['id']?.toString(),
    );
  }

  static List<ChatMessage> fromJsonMany(Map<String, dynamic> json) {
    final role = (json['role'] ?? 'assistant').toString();
    final persistedId = json['id']?.toString();
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
          persistedId: persistedId,
        ),
      ];
    }

    final result = <ChatMessage>[];
    final message = ChatMessage.fromJson(json);
    if (message.text.isNotEmpty) result.add(message);

    final content = json['content'];
    final toolCalls =
        json['tool_calls'] ??
        (content is List
            ? content
                  .whereType<Map>()
                  .where((part) => part['type'] == 'tool_use')
                  .toList(growable: false)
            : null);
    if (toolCalls is List) {
      for (final rawCall in toolCalls.whereType<Map>()) {
        final call = rawCall.cast<String, dynamic>();
        final function = call['function'] is Map
            ? (call['function'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        dynamic arguments =
            function['arguments'] ?? call['arguments'] ?? call['input'];
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
            persistedId: persistedId,
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
  final started = events.where((event) => event.toolState == 'started');
  final representatives = <ChatEvent>[];
  final seenIds = <String>{};
  for (final event in started) {
    final id = event.toolCallId;
    if (id == null || seenIds.add(id)) representatives.add(event);
  }
  final hasStarted = representatives.isNotEmpty;
  for (final event in events) {
    if (event.toolState == 'started') continue;
    final id = event.toolCallId;
    if (id != null && seenIds.add(id)) {
      representatives.add(event);
    } else if (id == null && !hasStarted) {
      representatives.add(event);
    }
  }
  return representatives;
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
