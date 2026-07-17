# Native Android migration (complete)

Hermes Chat is now a native Kotlin/Jetpack Compose Android client. The Flutter client has been retired.

## Architecture

- `HermesClient`: OkHttp WebSocket/HTTP transport for Hermes Desktop, with JSON-RPC request correlation, event Flow, cookies/token auth, bounded reconnect backoff, session history, and `/api/audio/transcribe`.
- `ChatViewModel`: unidirectional `StateFlow<ChatUiState>`, session/runtime-ID mapping, streaming timeline updates, approval/cancel actions, and `SavedStateHandle` restoration after process recreation.
- `SecureCredentials`: Android Keystore-backed encrypted preferences.
- Compose UI: adaptive session/chat layout, search/create/resume, streaming messages, grouped semantic tool cards, Markdown, approval prompts, cancellation, and voice recording/transcription.

## Protocol compatibility

WebSocket URL: `<server>/api/ws?token=…` for token auth, or `<server>/api/ws?ticket=…` after password login and `POST /api/auth/ws-ticket`.

JSON-RPC request:

```json
{"jsonrpc":"2.0","id":"mobile-1","method":"session.list","params":{"limit":200}}
```

Server event:

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"runtime-id","payload":{"text":"Hello"}}}
```

Audio transcription uses `POST /api/audio/transcribe` with `{ "data_url": "data:audio/mp4;base64,…", "mime_type": "audio/mp4" }` and reads `transcript` from the response.

## Build and test

```bash
./native-android/gradlew -p native-android spotlessCheck lintDebug testDebugUnitTest assembleDebug assembleDebugAndroidTest
```

## Signing

Release APKs are signed with the same 4096-bit RSA key (alias `hermes-chat`) previously used for the Flutter APK. See `native-android/SIGNING.md`.
