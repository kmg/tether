defmodule TetherWeb.PageController do
  use TetherWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
