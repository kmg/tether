# Tether

Monitor and respond to Claude Code from your phone.

Tether connects to your tmux sessions and gives you:

- **Push notifications** — your phone buzzes when Claude needs input
- **Activity detection** — see which windows have Claude waiting vs working at a glance
- **Mobile terminal** — tap to attach, type a response, done. No keyboard shortcuts needed.
- **Works from any browser** — phone, tablet, another laptop

## How it works

You run Claude Code in tmux. Tether watches your tmux sessions,
detects when Claude is waiting for input, and sends a push notification
to your phone. Tap the notification, type your response in the
browser terminal, and get back to what you were doing.

No SSH client app. No keyboard shortcuts. Just a browser.

## Quick start

```bash
brew tap kmg/tether
brew install tether
tether start
```

Open the URL printed in your terminal (includes auth token).

## Manual install

Requires Elixir 1.15+ and Erlang/OTP 27+.

```bash
git clone https://github.com/kmg/tether.git
cd tether
mix setup
mix phx.server
```

Open http://localhost:7374 in your browser.

## Configuration

Tether is configured via environment variables. When running as a release,
defaults are auto-generated on first run.

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `7374` | HTTP port |
| `PHX_HOST` | `localhost` | Hostname for URLs |
| `TETHER_TOKEN` | auto-generated | Auth token (printed on startup) |
| `SECRET_KEY_BASE` | auto-generated | Phoenix session secret |
| `TETHER_DATA_DIR` | `~/.local/share/tether` | Persistent data directory |

### TLS (optional)

For HTTPS (e.g., via Tailscale):

```bash
export TLS_CERTFILE=/path/to/cert.pem
export TLS_KEYFILE=/path/to/key.pem
```

### Push notifications (optional)

Generate VAPID keys in iex:

```elixir
Tether.Notifier.generate_vapid_keys()
```

Then set:

```bash
export VAPID_PUBLIC_KEY=...
export VAPID_PRIVATE_KEY=...
export VAPID_SUBJECT=mailto:you@example.com
```

## Development

```bash
cp .env.example .env
# Edit .env with your values
source .env && mix phx.server
```

## How tmux detection works

Tether polls `tmux list-windows` and reads pane content to detect Claude Code's
activity indicator. When Claude transitions from "working" to "waiting for input",
Tether sends a push notification. The detection is based on terminal content
pattern matching — no Claude API integration required.

## License

MIT
