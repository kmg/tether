defmodule TetherWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :tether

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_tether_key",
    signing_salt: "aDMwp3rD",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [compress: true, connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # Cache: 1 year for all static assets. Phoenix digest ensures
  # filenames change when content changes. Service worker handles
  # smart caching strategies (cache-first for assets, network-first for HTML).
  plug Plug.Static,
    at: "/",
    from: :tether,
    gzip: not code_reloading?,
    only: TetherWeb.static_paths(),
    raise_on_missing_only: code_reloading?,
    headers: %{"cache-control" => "public, max-age=31536000, immutable"}

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug TetherWeb.Router
end
