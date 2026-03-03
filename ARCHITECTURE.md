# Architecture

## How detection works

Tether polls `tmux capture-pane` every 5 seconds for each window running Claude Code. It reads the terminal content and pattern-matches against Claude's activity indicator to determine state: working, waiting for input, or idle.

When Claude transitions from working to waiting, Tether sends a push notification. Detection is purely terminal content pattern matching — no Claude API integration, no special hooks. Works with any version of Claude Code.

```
ClaudeMonitor (GenServer)
    │
    ├── polls tmux capture-pane every 5s
    ├── ActivityParser.parse(content) → {:waiting, _} | {:tool, _, _} | {:working, _} | {:idle, _}
    │
    ├── on :waiting transition:
    │   ├── Notifier.notify_claude_waiting() → Web Push to all subscribers
    │   └── PubSub broadcast → LiveView UI update
    │
    └── on activity change:
        └── PubSub broadcast → LiveView UI update
```

## Notification pipeline

```
Phone (PWA) ◄── Tailscale ◄── Phoenix (HTTPS :7374)
                                       │
                                 LiveView
                             ┌─────┴─────┐
                       HomeLive     TerminalLive
                       (browse)      (xterm.js)
                                       │
                                 WindowSession
                                 (GenServer + PTY)
                                       │
                                  tmux window
                                       │
  ClaudeMonitor ──────────── capture-pane polling
  (background)                         │
       │                         Push notification
       ▼                         when waiting detected
  PubSub broadcast
```

Push notifications use Web Push (RFC 8291 + RFC 8292) with a standalone implementation — ECDH key agreement, AES-128-GCM encryption, VAPID JWT signing. All using Erlang's built-in `:crypto` module and `:httpc`. No external crypto or HTTP dependencies.

## Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Framework | Phoenix LiveView | Real-time updates over WebSocket, Elixir supervision trees for process management |
| Terminal | xterm.js (canvas renderer) | Industry standard terminal emulator, full VT100+ support |
| PTY | erlexec | Proper pseudo-terminal for bidirectional tmux I/O |
| Notifications | Web Push API | No app install needed, works on iOS (16.4+) and Android as a PWA |
| TLS | Tailscale certs | No reverse proxy — direct HTTPS means fewer hops and more reliable WebSocket reconnection on mobile |
| Auth | Token-based | Auto-generated on first run, 30-day session cookie |
| Database | None | ETS for in-memory state, JSON file for push subscriptions. tmux is the source of truth. |
| Distribution | Homebrew tap | `brew install`, OTP release with bundled ERTS — no Elixir or Erlang needed on the user's machine |

## Manual install

Requires Elixir 1.15+ and Erlang/OTP 27+.

```bash
git clone https://github.com/kmg/tether.git
cd tether
mix setup
mix phx.server
```

Open http://localhost:7374 in your browser.

## Development

```bash
cp .env.example .env
# Edit .env with your values
source .env && mix phx.server
```

## License

MIT
