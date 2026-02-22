defmodule Tether.Notifier do
  @moduledoc """
  Web Push notification sender.
  Stores subscriptions in ETS (with file persistence) and sends notifications when Claude needs input.
  """
  use GenServer
  require Logger

  @table :push_subscriptions
  @storage_file "priv/data/subscriptions.json"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(@table, [:set, :public, :named_table])
    load_from_file()
    {:ok, %{}}
  end

  @doc """
  Store a push subscription.
  """
  def subscribe(subscription) do
    # Normalize subscription to have atom keys for the nested keys map
    normalized = normalize_subscription(subscription)
    :ets.insert(@table, {subscription["endpoint"], normalized})
    save_to_file()
    :ok
  end

  @doc """
  Remove a push subscription.
  """
  def unsubscribe(endpoint) do
    :ets.delete(@table, endpoint)
    save_to_file()
    :ok
  end

  @doc """
  Send notification to all subscribers.
  """
  def notify(title, body, data \\ %{}) do
    if vapid_configured?() do
      subscriptions = :ets.tab2list(@table)

      for {_endpoint, subscription} <- subscriptions do
        send_push(subscription, title, body, data)
      end

      :ok
    else
      Logger.warning("VAPID keys not configured, skipping push notification")
      :ok
    end
  end

  @doc """
  Notify that Claude needs input in a specific window.
  """
  def notify_claude_waiting(session, window_index, window_name) do
    notify(
      "Claude needs input",
      "#{session} → #{window_name}",
      %{session: session, window: window_index}
    )
  end

  defp send_push(subscription, title, body, data) do
    payload =
      Jason.encode!(%{
        title: title,
        body: body,
        data: data,
        icon: "/images/icon-192.png",
        badge: "/images/badge-72.png"
      })

    try do
      case Tether.WebPush.send(payload, subscription) do
        {:ok, %{status_code: code}} when code in 200..299 ->
          Logger.info("Push sent to #{subscription.endpoint}")
          :ok

        {:ok, %{status_code: 404}} ->
          Logger.warning("Push subscription not found, removing")
          unsubscribe(subscription.endpoint)
          :error

        {:ok, %{status_code: 410}} ->
          Logger.warning("Push subscription expired, removing")
          unsubscribe(subscription.endpoint)
          :error

        {:ok, %{status_code: code, body: resp_body}} ->
          Logger.warning("Push failed with status #{code}: #{resp_body}")
          :error

        {:error, reason} ->
          Logger.warning("Push failed: #{inspect(reason)}")
          :error
      end
    rescue
      e ->
        Logger.warning("Push error for #{subscription.endpoint}: #{Exception.message(e)}")
        :error
    end
  end

  # Normalize subscription from JS format to what WebPushEncryption expects
  defp normalize_subscription(sub) when is_map(sub) do
    keys = sub["keys"] || %{}

    %{
      endpoint: sub["endpoint"],
      keys: %{
        auth: keys["auth"],
        p256dh: keys["p256dh"]
      }
    }
  end

  defp vapid_configured? do
    case Application.get_env(:web_push_encryption, :vapid_details) do
      nil -> false
      details -> details[:public_key] && details[:private_key]
    end
  end

  @doc """
  Generate new VAPID keys (for initial setup).
  Run in iex: Tether.Notifier.generate_vapid_keys()
  """
  def generate_vapid_keys do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      public_key: Base.url_encode64(public, padding: false),
      private_key: Base.url_encode64(private, padding: false)
    }
  end

  @doc """
  Get the public VAPID key for client subscription.
  """
  def vapid_public_key do
    case Application.get_env(:web_push_encryption, :vapid_details) do
      nil -> nil
      details -> details[:public_key]
    end
  end

  # File persistence

  defp storage_path do
    case System.get_env("TETHER_DATA_DIR") do
      nil -> Path.join(Application.app_dir(:tether), @storage_file)
      dir -> Path.join(dir, "subscriptions.json")
    end
  end

  defp load_from_file do
    path = storage_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, subscriptions} when is_list(subscriptions) ->
              for sub <- subscriptions do
                normalized = %{
                  endpoint: sub["endpoint"],
                  keys: %{
                    auth: sub["keys"]["auth"],
                    p256dh: sub["keys"]["p256dh"]
                  }
                }

                :ets.insert(@table, {sub["endpoint"], normalized})
              end

              Logger.info("Loaded #{length(subscriptions)} push subscriptions from file")

            _ ->
              Logger.warning("Invalid subscriptions file format")
          end

        {:error, reason} ->
          Logger.warning("Failed to read subscriptions file: #{inspect(reason)}")
      end
    end
  end

  defp save_to_file do
    path = storage_path()
    File.mkdir_p!(Path.dirname(path))

    subscriptions =
      :ets.tab2list(@table)
      |> Enum.map(fn {_endpoint, sub} ->
        %{
          "endpoint" => sub.endpoint,
          "keys" => %{
            "auth" => sub.keys.auth,
            "p256dh" => sub.keys.p256dh
          }
        }
      end)

    File.write!(path, Jason.encode!(subscriptions, pretty: true))
  end
end
