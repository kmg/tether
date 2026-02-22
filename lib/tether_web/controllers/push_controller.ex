defmodule TetherWeb.PushController do
  use TetherWeb, :controller

  alias Tether.Notifier

  def subscribe(conn, %{"subscription" => subscription}) do
    Notifier.subscribe(subscription)
    json(conn, %{status: "subscribed"})
  end

  def unsubscribe(conn, %{"endpoint" => endpoint}) do
    Notifier.unsubscribe(endpoint)
    json(conn, %{status: "unsubscribed"})
  end

  def vapid_key(conn, _params) do
    case Notifier.vapid_public_key() do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "VAPID keys not configured"})

      key ->
        json(conn, %{vapid_public_key: key})
    end
  end

  def test(conn, params) do
    subs = :ets.tab2list(:push_subscriptions)

    if length(subs) > 0 do
      case params do
        %{"session" => session, "window" => window} ->
          window_idx = if is_binary(window), do: String.to_integer(window), else: window
          Notifier.notify_claude_waiting(session, window_idx, "claude")

        _ ->
          Notifier.notify("Test Notification", "This is a test from Tether!")
      end

      json(conn, %{status: "sent", subscribers: length(subs)})
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "No subscribers", subscribers: 0})
    end
  end
end
