import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/sse_parser.dart';

void main() {
  test('parses named SSE event with multiline data', () {
    final events = SseParser.parse(
      'event: tool.started\ndata: {"name":"terminal",\ndata: "status":"running"}\n\n',
    );
    expect(events, hasLength(1));
    expect(events.single.type, 'tool.started');
    expect(events.single.data, '{"name":"terminal",\n"status":"running"}');
  });

  test('ignores comments and defaults event type to message', () {
    final events = SseParser.parse(': keep-alive\ndata: hello\n\n');
    expect(events.single.type, 'message');
    expect(events.single.data, 'hello');
  });
}
