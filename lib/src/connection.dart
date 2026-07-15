import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ConnectionConfig {
  const ConnectionConfig({required this.baseUrl, required this.token});

  final String baseUrl;
  final String token;

  String get normalizedBaseUrl =>
      baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
}

class ConnectionStore {
  ConnectionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<ConnectionConfig?> load() async {
    final values = await _storage.readAll();
    final url = values['hermes.baseUrl'];
    final token = values['hermes.token'];
    if (url == null || token == null || url.isEmpty || token.isEmpty) {
      return null;
    }
    return ConnectionConfig(baseUrl: url, token: token);
  }

  Future<void> save(ConnectionConfig config) async {
    await _storage.write(
      key: 'hermes.baseUrl',
      value: config.normalizedBaseUrl,
    );
    await _storage.write(key: 'hermes.token', value: config.token.trim());
  }
}
