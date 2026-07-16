import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ConnectionConfig {
  const ConnectionConfig({
    required this.baseUrl,
    this.username = '',
    this.password = '',
    this.token = '',
  });

  final String baseUrl;
  final String username;
  final String password;
  final String token;

  String get normalizedBaseUrl =>
      baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');

  String? get validationError {
    final uri = Uri.tryParse(normalizedBaseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'Enter a complete Hermes backend URL.';
    }
    if (uri.scheme == 'https') return null;
    if (uri.scheme != 'http') return 'Use an HTTP or HTTPS URL.';
    final host = uri.host.toLowerCase();
    final trustedHttp =
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.ts.net') ||
        host.startsWith('10.') ||
        host.startsWith('192.168.') ||
        _isPrivate172(host) ||
        _isTailscaleV4(host) ||
        host.startsWith('fd7a:115c:a1e0:');
    return trustedHttp
        ? null
        : 'Plain HTTP is only allowed for localhost, private networks, or Tailscale. Use HTTPS for public servers.';
  }

  static bool _isPrivate172(String host) {
    final parts = host.split('.');
    final second = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return parts.firstOrNull == '172' &&
        second != null &&
        second >= 16 &&
        second <= 31;
  }

  static bool _isTailscaleV4(String host) {
    final parts = host.split('.');
    final second = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return parts.firstOrNull == '100' &&
        second != null &&
        second >= 64 &&
        second <= 127;
  }
}

class ConnectionStore {
  ConnectionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<ConnectionConfig?> load() async {
    final values = await _storage.readAll();
    final url = values['hermes.baseUrl'];
    if (url == null || url.isEmpty) return null;
    final username = values['hermes.username'] ?? '';
    final password = values['hermes.password'] ?? '';
    final token = values['hermes.token'] ?? '';
    if ((username.isEmpty || password.isEmpty) && token.isEmpty) return null;
    return ConnectionConfig(
      baseUrl: url,
      username: username,
      password: password,
      token: token,
    );
  }

  Future<void> save(ConnectionConfig config) async {
    await _storage.write(
      key: 'hermes.baseUrl',
      value: config.normalizedBaseUrl,
    );
    await _storage.write(key: 'hermes.username', value: config.username.trim());
    await _storage.write(key: 'hermes.password', value: config.password);
    await _storage.write(key: 'hermes.token', value: config.token.trim());
  }
}
