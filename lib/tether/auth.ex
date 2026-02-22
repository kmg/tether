defmodule Tether.Auth do
  @moduledoc """
  Token-based authentication plug (Livebook-style).

  On first visit, redirects to /auth where the user enters a token.
  The token is displayed in the terminal on startup and auto-generated
  on first run (stored in TETHER_DATA_DIR/.token).

  Once authenticated, a long-lived session cookie (30 days) is set.
  """
  import Plug.Conn
  import Phoenix.Controller

  @session_key :tether_authenticated
  @max_age 30 * 24 * 3600

  def init(opts), do: opts

  def call(conn, _opts) do
    # Skip auth when no token is configured (e.g., dev mode)
    if expected_token() == nil or authenticated?(conn) do
      conn
    else
      conn
      |> redirect(to: "/auth")
      |> halt()
    end
  end

  @doc """
  Check if the connection has a valid auth session.
  """
  def authenticated?(conn) do
    get_session(conn, @session_key) == true
  end

  @doc """
  Mark the connection as authenticated by setting the session.
  """
  def authenticate(conn) do
    conn
    |> put_session(@session_key, true)
    |> configure_session(max_age: @max_age)
  end

  @doc """
  Validate the given token against the expected token.
  """
  def valid_token?(token) do
    expected = expected_token()
    expected != nil && Plug.Crypto.secure_compare(token, expected)
  end

  @doc """
  Get the expected token from the environment.
  """
  def expected_token do
    System.get_env("TETHER_TOKEN")
  end

  @doc """
  Generate a random URL-safe token.
  """
  def generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
