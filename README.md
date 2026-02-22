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

### Remote access via Tailscale (optional)

Tether works on localhost by default. To access it from your phone over your
Tailscale network with HTTPS:

1. Install Tailscale if you haven't: `brew install tailscale`

2. Get your machine's Tailscale hostname:

    ```bash
    tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//'
    ```

3. Generate TLS certs for your hostname:

    ```bash
    tailscale cert YOUR-MACHINE.tail1234.ts.net
    ```

    This creates two files in the current directory:
    `YOUR-MACHINE.tail1234.ts.net.crt` and `YOUR-MACHINE.tail1234.ts.net.key`

4. Move the certs somewhere persistent and configure Tether:

    ```bash
    mkdir -p ~/.local/share/tether/cert
    mv YOUR-MACHINE.tail1234.ts.net.* ~/.local/share/tether/cert/

    # Add to your shell profile (~/.zshrc or ~/.bashrc):
    export TLS_CERTFILE="$HOME/.local/share/tether/cert/YOUR-MACHINE.tail1234.ts.net.crt"
    export TLS_KEYFILE="$HOME/.local/share/tether/cert/YOUR-MACHINE.tail1234.ts.net.key"
    export PHX_HOST="YOUR-MACHINE.tail1234.ts.net"
    ```

5. Restart Tether:

    ```bash
    brew services restart tether
    ```

6. Open `https://YOUR-MACHINE.tail1234.ts.net:7374` on your phone
   (must be on the same Tailscale network).

The auth token is the same — it's printed in the logs at
`/opt/homebrew/var/log/tether.log`, or check `~/.local/share/tether/.token`.

### TLS without Tailscale

Any TLS certs work. Set `TLS_CERTFILE` and `TLS_KEYFILE` environment variables:

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
