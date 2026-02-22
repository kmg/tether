defmodule TetherWeb.AuthController do
  use TetherWeb, :controller

  alias Tether.Auth

  def callback(conn, %{"token" => token}) do
    if Auth.valid_token?(token) do
      conn
      |> Auth.authenticate()
      |> redirect(to: "/")
    else
      conn
      |> redirect(to: "/auth")
    end
  end
end
