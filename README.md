# Hermes Chat

A focused Flutter client for Hermes Agent on Android and Linux.

The app connects to the same authenticated `hermes serve` backend as Hermes Desktop. Chat, session history, tool activity, approvals, interruption, and voice transcription therefore use Hermes' native WebSocket/JSON-RPC and HTTP surfaces rather than the OpenAI-compatible API Server.

## MVP features

- Responsive session list (desktop split view, mobile navigation)
- Create and resume native Hermes sessions
- Search sessions by title and preview text
- Record voice messages and transcribe them through Hermes' built-in `/api/audio/transcribe` endpoint
- Stream assistant responses and structured tool activity over `/api/ws`
- Review dangerous tool requests and allow once, always allow, or deny
- Interrupt a running response
- Group four or more consecutive tool calls with expandable details
- Store backend URL and credentials in platform secure storage
- Android and Linux targets with CI release artifacts

## Hermes setup

Run an authenticated `hermes serve` backend. Hermes Chat supports the same username/password login used by Hermes Desktop:

```bash
hermes serve --host 0.0.0.0 --port 9119
```

The server must have `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, a password or password hash, and a stable `HERMES_DASHBOARD_BASIC_AUTH_SECRET` configured. Keep it on a trusted network such as Tailscale; never expose a password-authenticated Hermes backend directly to the public internet.

HTTPS is required for public hosts. Plain HTTP is accepted only for localhost, private-network addresses, and Tailscale hosts because the underlying tunnel already encrypts tailnet traffic.
