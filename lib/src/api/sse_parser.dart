class SseEvent {
  const SseEvent({required this.type, required this.data});

  final String type;
  final String data;
}

class SseParser {
  static List<SseEvent> parse(String input) {
    final normalized = input.replaceAll('\r\n', '\n');
    return normalized
        .split('\n\n')
        .map(_parseBlock)
        .whereType<SseEvent>()
        .toList(growable: false);
  }

  static SseEvent? _parseBlock(String block) {
    var type = 'message';
    final data = <String>[];
    for (final line in block.split('\n')) {
      if (line.startsWith(':') || line.isEmpty) continue;
      if (line.startsWith('event:')) {
        type = line.substring(6).trimLeft();
      } else if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      }
    }
    if (data.isEmpty) return null;
    return SseEvent(type: type, data: data.join('\n'));
  }
}
