import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_chat/src/api/hermes_api.dart';
import 'package:hermes_chat/src/connection.dart';

void main() {
  final baseUrl = Platform.environment['HERMES_SERVE_TEST_URL'];
  final token = Platform.environment['HERMES_SERVE_TEST_TOKEN'];
  final username = Platform.environment['HERMES_SERVE_TEST_USERNAME'];
  final password = Platform.environment['HERMES_SERVE_TEST_PASSWORD'];
  final hasCredentials =
      token != null || (username != null && password != null);

  test(
    'connects to a live Hermes serve JSON-RPC backend',
    () async {
      final api = HermesApi(
        ConnectionConfig(
          baseUrl: baseUrl!,
          token: token ?? '',
          username: username ?? '',
          password: password ?? '',
        ),
      );
      await api.checkHealth();
      final sessions = await api.listSessions();
      final created = await api.createSession(title: 'Mobile smoke test');

      expect(sessions, isA<List>());
      expect(created.id, isNotEmpty);

      final recording = File(
        '${Directory.systemTemp.path}/hermes-mobile-live-smoke.m4a',
      );
      await recording.writeAsBytes([0, 0, 0, 24, 102, 116, 121, 112]);
      try {
        await api.transcribeAudio(recording.path);
      } on HermesApiException catch (error) {
        expect(error.statusCode, isNot(anyOf(401, 404)));
      } finally {
        if (await recording.exists()) await recording.delete();
      }
      api.close();
    },
    skip: baseUrl == null || !hasCredentials
        ? 'Set a live URL plus token or username/password'
        : false,
  );
}
