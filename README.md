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

### 1. Start Claude Code in tmux

Tether monitors tmux sessions, so Claude Code needs to be running inside one:

```bash
tmux new-session -s work
claude
```

If you already use tmux, you're set — Tether detects Claude in any window
of any session.

### 2. Install and start Tether

```bash
brew tap kmg/tether
brew install tether
tether start
```

Open the URL printed in your terminal. It includes a one-time auth token —
paste it into the login screen and you're in. The session lasts 30 days.

## Authentication

Tether generates a random token on first run, stored at
`~/.local/share/tether/.token`. The token is printed to the terminal
(or to `/opt/homebrew/var/log/tether.log` when using `brew services`).

Every route requires authentication. On first visit you'll see a token
input screen — paste the token from the URL or the file. Once
authenticated, a session cookie keeps you logged in for 30 days.

To use a custom token, set `TETHER_TOKEN` in your env file (see
[Configuration](#configuration)).

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

Tether is configured via environment variables. When running as a release
(via `brew install`), defaults are auto-generated on first run.

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `7374` | HTTP/HTTPS port |
| `PHX_HOST` | `localhost` | Hostname for URLs |
| `TETHER_TOKEN` | auto-generated | Auth token (printed on startup) |
| `SECRET_KEY_BASE` | auto-generated | Phoenix session secret |
| `TETHER_DATA_DIR` | `~/.local/share/tether` | Persistent data directory |
| `TLS_CERTFILE` | — | Path to TLS certificate (enables HTTPS) |
| `TLS_KEYFILE` | — | Path to TLS private key (enables HTTPS) |
| `VAPID_PUBLIC_KEY` | — | VAPID public key (enables push notifications) |
| `VAPID_PRIVATE_KEY` | — | VAPID private key (enables push notifications) |
| `VAPID_SUBJECT` | `mailto:tether@localhost` | VAPID contact URI |

### Env file

The recommended way to configure a brew-installed Tether is the env file
at `~/.local/share/tether/env`. It's sourced on every start — no need to
modify your shell profile.

```bash
# ~/.local/share/tether/env
TLS_CERTFILE=/Users/you/.local/share/tether/cert/your-host.ts.net.crt
TLS_KEYFILE=/Users/you/.local/share/tether/cert/your-host.ts.net.key
PHX_HOST=your-host.ts.net
VAPID_PUBLIC_KEY=BLa...
VAPID_PRIVATE_KEY=dGV...
```

No `export` needed — the release script handles that.

### HTTPS via Tailscale

Tether runs HTTP on localhost by default. For phone access and push
notifications, you need HTTPS. Tailscale gives you free TLS certs
that work across your private network.

1. Install Tailscale: `brew install --cask tailscale`

2. Get your machine's hostname:

    ```bash
    tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//'
    ```

3. Generate certs and move them to Tether's data dir:

    ```bash
    mkdir -p ~/.local/share/tether/cert
    cd ~/.local/share/tether/cert
    tailscale cert YOUR-MACHINE.tail1234.ts.net
    ```

4. Create the env file:

    ```bash
    cat > ~/.local/share/tether/env << 'EOF'
    TLS_CERTFILE=/Users/you/.local/share/tether/cert/YOUR-MACHINE.tail1234.ts.net.crt
    TLS_KEYFILE=/Users/you/.local/share/tether/cert/YOUR-MACHINE.tail1234.ts.net.key
    PHX_HOST=YOUR-MACHINE.tail1234.ts.net
    EOF
    ```

5. Restart Tether:

    ```bash
    brew services restart tether
    ```

6. Open `https://YOUR-MACHINE.tail1234.ts.net:7374` on your phone
   (must be on the same Tailscale network).

### HTTPS without Tailscale

Any TLS certs work. Add `TLS_CERTFILE` and `TLS_KEYFILE` to your env file.
When both are set and the files exist, Tether switches to HTTPS automatically.

### Push notifications

Push notifications require **HTTPS** (or localhost). Browsers only allow
Service Workers — which power push notifications — on secure contexts.
If you're accessing Tether over `http://192.168.x.x`, push won't work.
Set up HTTPS first (see above).

1. Generate VAPID keys:

    ```bash
    tether remote
    iex> Tether.Notifier.generate_vapid_keys()
    ```

    This prints a public/private key pair.

2. Add the keys to your env file (`~/.local/share/tether/env`):

    ```
    VAPID_PUBLIC_KEY=BLa...
    VAPID_PRIVATE_KEY=dGV...
    ```

3. Restart Tether:

    ```bash
    brew services restart tether
    ```

4. Open Tether in your phone's browser and accept the notification
   prompt. You'll get a push whenever Claude is waiting for input.

5. **Add to Home Screen** — for an app-like experience, save Tether to
   your home screen. On iOS Safari: tap the share button → "Add to Home
   Screen". On Android Chrome: tap the menu → "Add to Home screen".
   This gives you a standalone window (no browser chrome) and ensures
   notifications work reliably in the background.

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
