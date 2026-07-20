# Hermes Chat

A native Kotlin/Jetpack Compose Android client for Hermes Agent.

## Download

**[Download the newest signed Android APK](https://github.com/qelg/hermes-chat/releases/download/latest/hermes-chat-latest.apk)**

This stable link is updated automatically after every successful CI build on `main`.

The app connects to Hermes Agent's authenticated API Server. It uses the same persistent session database as the dashboard, while exposing a deliberately client-safe subset over REST and SSE.

## MVP features

- Responsive session list (desktop split view, mobile navigation)
- Create and resume persistent Hermes sessions
- Search sessions by title and preview text
- Stream assistant responses and structured tool activity through controllable API runs
- Review dangerous tool requests and allow once, always allow, or deny
- Stop a running response through the server-side run control endpoint
- Group four or more consecutive tool calls with expandable details
- Store the API Server URL and API key in platform secure storage
- Show cumulative token usage and enabled API-server toolsets

The API Server currently does not expose audio transcription, interactive clarify responses, detailed context composition, or per-session model switching. Those controls are therefore not offered by the app.

## Hermes setup

Enable Hermes Agent's authenticated API Server and connect using its URL and `API_SERVER_KEY`. The default local endpoint is:

```text
http://127.0.0.1:8642
```

For a phone, publish it through a trusted encrypted network such as Tailscale and use HTTPS, for example `https://host.example.ts.net:8643`. Never expose the API key or an unencrypted public endpoint.

HTTPS is required for public hosts. Plain HTTP is accepted only for localhost, private-network addresses, and Tailscale hosts because the underlying tunnel already encrypts tailnet traffic.

## Build and test

```bash
./native-android/gradlew -p native-android spotlessCheck lintDebug testDebugUnitTest assembleDebug assembleDebugAndroidTest
```
