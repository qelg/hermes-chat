# Hermes Chat

A focused Flutter client for Hermes Agent on Android and Linux.

The app talks directly to Hermes' authenticated API Server and uses the Sessions API for native chat history and SSE tool progress.

## MVP features

- Responsive session list (desktop split view, mobile navigation)
- Create and resume native Hermes sessions
- Streaming assistant responses through the Sessions API
- Compact tool-progress rows with expandable raw details
- Configurable server URL and bearer token stored in platform secure storage
- Android and Linux targets with CI release artifacts

## Hermes setup

Enable the API Server on the Hermes host and expose it only through a trusted HTTPS path (for example Tailscale Serve):

```dotenv
API_SERVER_ENABLED=true
API_SERVER_KEY=<strong-random-secret>
```

The app expects a base URL such as `https://hermes.example.ts.net` (without `/v1`). Never expose the API Server directly to the public internet: it has access to Hermes' full toolset.
