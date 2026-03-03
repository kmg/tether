defmodule Tether.ClaudeMonitor do
  @moduledoc """
  Background process that monitors all Claude windows for input prompts.
  Polls tmux capture-pane periodically and sends notifications when prompts detected.
  """
  use GenServer
  require Logger

  alias Tether.{Tmux, Notifier, ActivityParser}

  @poll_interval :timer.seconds(5)

  defstruct [
    :timer_ref,
    waiting_windows: MapSet.new(),
    active_sessions: MapSet.new(),
    activities: %{}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Start polling after a short delay to let the app boot
    timer_ref = Process.send_after(self(), :poll, 1000)
    {:ok, %__MODULE__{timer_ref: timer_ref}}
  end

  @doc """
  Get the current set of windows waiting for input.
  """
  def waiting_windows do
    GenServer.call(__MODULE__, :waiting_windows)
  end

  @doc """
  Get the current activity map: %{"session:window" => "display string"}
  """
  def activities do
    GenServer.call(__MODULE__, :activities)
  end

  @doc """
  Register a session as actively being viewed (suppresses notifications).
  """
  def register_active(target) do
    GenServer.cast(__MODULE__, {:register_active, target})
  end

  @doc """
  Unregister a session when no longer actively viewed.
  """
  def unregister_active(target) do
    GenServer.cast(__MODULE__, {:unregister_active, target})
  end

  def handle_call(:waiting_windows, _from, state) do
    {:reply, state.waiting_windows, state}
  end

  def handle_call(:activities, _from, state) do
    {:reply, state.activities, state}
  end

  def handle_cast({:register_active, target}, state) do
    active = Map.get(state, :active_sessions, MapSet.new())
    {:noreply, %{state | active_sessions: MapSet.put(active, target)}}
  end

  def handle_cast({:unregister_active, target}, state) do
    active = Map.get(state, :active_sessions, MapSet.new())
    {:noreply, %{state | active_sessions: MapSet.delete(active, target)}}
  end

  def handle_info(:poll, state) do
    new_state = poll_claude_windows(state)
    timer_ref = Process.send_after(self(), :poll, @poll_interval)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  defp poll_claude_windows(state) do
    case Tmux.find_claude_windows() do
      {:ok, windows} ->
        check_windows_for_prompts(windows, state)

      {:error, reason} ->
        Logger.debug("Failed to find Claude windows: #{inspect(reason)}")
        state
    end
  end

  defp check_windows_for_prompts(windows, state) do
    # Capture pane content once per window, run both waiting + activity checks
    window_states =
      Enum.map(windows, fn window ->
        case Tmux.capture_pane(window.session, window.index, 30, escape_sequences: false) do
          {:ok, content} ->
            parsed = ActivityParser.parse(content)
            waiting = match?({:waiting, _}, parsed)
            activity = ActivityParser.to_display_string(parsed)
            {window, waiting, activity}

          {:error, _} ->
            {window, false, nil}
        end
      end)

    # --- Waiting state ---
    currently_waiting =
      window_states
      |> Enum.filter(fn {_, waiting, _} -> waiting end)
      |> Enum.map(fn {w, _, _} -> w.target end)
      |> MapSet.new()

    prev_waiting = state.waiting_windows
    newly_waiting = MapSet.difference(currently_waiting, prev_waiting)

    for target <- newly_waiting do
      window = Enum.find(windows, &(&1.target == target))

      if window do
        Logger.info("Claude waiting for input: #{target}")

        active = state.active_sessions

        unless MapSet.member?(active, target) do
          Task.start(fn ->
            try do
              Notifier.notify_claude_waiting(window.session, window.index, window.name)
            rescue
              e -> Logger.warning("Notification failed: #{inspect(e)}")
            end
          end)
        end

        Phoenix.PubSub.broadcast(Tether.PubSub, "claude_monitor", {:waiting, window})
      end
    end

    cleared = MapSet.difference(prev_waiting, currently_waiting)

    for target <- cleared do
      Phoenix.PubSub.broadcast(Tether.PubSub, "claude_monitor", {:cleared, target})
    end

    # --- Activity state ---
    new_activities =
      window_states
      |> Enum.map(fn {window, _, activity} -> {window.target, activity} end)
      |> Map.new()

    prev_activities = state.activities

    # Broadcast only changed activities
    for {target, activity} <- new_activities, Map.get(prev_activities, target) != activity do
      Phoenix.PubSub.broadcast(
        Tether.PubSub,
        "claude_monitor",
        {:activity, target, activity}
      )
    end

    %{state | waiting_windows: currently_waiting, activities: new_activities}
  end
end
