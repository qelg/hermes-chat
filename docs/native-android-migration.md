# Native Android migration

Hermes Chat now contains a native Kotlin/Jetpack Compose client in `native-android/` alongside the shipping Flutter app. The Flutter APK remains the stable download until the parity checklist below has been verified on real devices; removing Flutter is intentionally a separate change.

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

CI publishes `hermes-chat-native-preview.apk` as both a workflow artifact and a preview asset on the existing `latest` release while continuing to publish the Flutter APK as the stable artifact.

## Parity checklist

- [x] Password and token authentication
- [x] Session list, search, creation, resume, history, and refresh
- [x] Streaming assistant text and active-session refresh
- [x] Tool start/end cards, semantic icons, elapsed time, and grouping
- [x] Markdown assistant messages
- [x] Voice recording and `/api/audio/transcribe`
- [x] Approval prompts, permanent/once/deny choices, cancellation, and errors
- [x] Keystore-backed credential storage
- [x] Bounded reconnect and selected-session restoration through process recreation
- [x] Automated protocol/model/reconnect tests and CI-testable APK
- [ ] Real-device lifecycle/background soak test
- [ ] Explicit product approval to make native APK stable and retire Flutter

The unchecked release gates are deliberately required before Flutter retirement, matching Issue #12's non-goals.
