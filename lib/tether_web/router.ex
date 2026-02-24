defmodule TetherWeb.Router do
  use TetherWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TetherWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_auth do
    plug Tether.Auth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Auth routes — no auth required
  scope "/auth", TetherWeb do
    pipe_through :browser

    live "/", AuthLive
    get "/callback", AuthController, :callback
  end

  # Protected routes
  scope "/", TetherWeb do
    pipe_through [:browser, :require_auth]

    live "/", HomeLive
    live "/terminal/:session/:window", TerminalLive
  end

  # API routes — token checked via header or param
  scope "/api", TetherWeb do
    pipe_through :api

    post "/push/subscribe", PushController, :subscribe
    post "/push/confirm", PushController, :confirm
    delete "/push/subscribe", PushController, :unsubscribe
    get "/push/vapid-key", PushController, :vapid_key
    post "/push/test", PushController, :test
  end
end
