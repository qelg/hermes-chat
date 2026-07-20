# Native Android migration (complete)

Hermes Chat is now a native Kotlin/Jetpack Compose Android client. The Flutter client has been retired.

## Architecture

- `HermesClient`: OkHttp REST/SSE transport for Hermes Agent's API Server, with Bearer authentication, persistent session resources, event translation, and cancellable streamed turns.
- `ChatViewModel`: unidirectional `StateFlow<ChatUiState>`, persistent-session mapping, streaming timeline updates, cancellation, and `SavedStateHandle` restoration after process recreation.
- `SecureCredentials`: Android Keystore-backed encrypted preferences.
- Compose UI: adaptive session/chat layout, search/create/resume, streaming messages, grouped semantic tool cards, and Markdown.

## Protocol compatibility

All requests use `Authorization: Bearer <API_SERVER_KEY>`. The client verifies the endpoint through `GET /v1/capabilities`, reads sessions through `/api/sessions`, and submits controllable turns through `POST /v1/runs`. It then consumes structured events from `GET /v1/runs/{run_id}/events`.

The run events `message.delta`, `tool.started`, `tool.completed`, `approval.request`, `run.completed`, `run.failed`, and `run.cancelled` are translated into the existing timeline model. Approval decisions use `POST /v1/runs/{run_id}/approval`; stopping uses `POST /v1/runs/{run_id}/stop`, which interrupts the server-side agent before the client closes its event stream.

The client follows SessionDB compression children to the newest lineage leaf before continuing a conversation, while keeping the root session selected in the UI.

The API Server shares Hermes' persistent session database but deliberately omits the dashboard's audio transcription, detailed context breakdown, clarify responses, and per-session model-switching RPCs.

## Build and test

```bash
./native-android/gradlew -p native-android spotlessCheck lintDebug testDebugUnitTest assembleDebug assembleDebugAndroidTest
```

## Signing

Release APKs are signed with the same 4096-bit RSA key (alias `hermes-chat`) previously used for the Flutter APK. See `native-android/SIGNING.md`.
