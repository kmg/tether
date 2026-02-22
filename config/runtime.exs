import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# application starts.

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret

      If running via `mix release`, SECRET_KEY_BASE is auto-generated
      by rel/env.sh.eex on first run.
      """

  port = String.to_integer(System.get_env("PORT") || "7374")
  host = System.get_env("PHX_HOST") || "localhost"

  # Check for TLS certificates
  certfile = System.get_env("TLS_CERTFILE")
  keyfile = System.get_env("TLS_KEYFILE")
  has_tls? = certfile && keyfile && File.exists?(certfile) && File.exists?(keyfile)
  scheme = if has_tls?, do: "https", else: "http"

  endpoint_config = [
    url: [host: host, port: port, scheme: scheme],
    secret_key_base: secret_key_base,
    check_origin: false
  ]

  endpoint_config =
    if has_tls? do
      endpoint_config
      |> Keyword.put(:https,
        port: port,
        cipher_suite: :strong,
        certfile: certfile,
        keyfile: keyfile
      )
      |> Keyword.put(:force_ssl, rewrite_on: [:x_forwarded_proto])
    else
      Keyword.put(endpoint_config, :http,
        ip: {0, 0, 0, 0},
        port: port
      )
    end

  config :tether, TetherWeb.Endpoint, endpoint_config
end

# VAPID keys for Web Push notifications (all envs)
vapid_public = System.get_env("VAPID_PUBLIC_KEY")
vapid_private = System.get_env("VAPID_PRIVATE_KEY")

if vapid_public && vapid_private do
  config :web_push_encryption,
    vapid_details: [
      public_key: vapid_public,
      private_key: vapid_private,
      subject: System.get_env("VAPID_SUBJECT", "mailto:tether@localhost")
    ]
end
