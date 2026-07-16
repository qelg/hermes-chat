import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/connection.dart';

void main() {
  test('allows HTTPS and Tailscale/private HTTP backends', () {
    expect(
      const ConnectionConfig(baseUrl: 'https://example.com').validationError,
      isNull,
    );
    expect(
      const ConnectionConfig(
        baseUrl: 'http://home.example.ts.net:9119',
      ).validationError,
      isNull,
    );
    expect(
      const ConnectionConfig(
        baseUrl: 'http://100.100.20.30:9119',
      ).validationError,
      isNull,
    );
  });

  test('rejects credentials over public plain HTTP', () {
    expect(
      const ConnectionConfig(
        baseUrl: 'http://example.com:9119',
      ).validationError,
      contains('HTTPS'),
    );
  });
}
