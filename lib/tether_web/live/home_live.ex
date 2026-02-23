defmodule TetherWeb.HomeLive do
  @moduledoc """
  Session browser - lists all tmux sessions and their windows.
  Sessions loaded once on mount. Activity updates pushed via PubSub only — no timers.
  """
  use TetherWeb, :live_view

  alias Tether.{Tmux, ClaudeMonitor}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tether.PubSub, "claude_monitor")
    end

    {:ok,
     socket
     |> assign(sessions: [], waiting: MapSet.new(), activities: %{}, loading: true)
     |> load_sessions()}
  end

  # PubSub handlers — the only source of updates after mount

  def handle_info({:waiting, window}, socket) do
    {:noreply, update(socket, :waiting, &MapSet.put(&1, window.target))}
  end

  def handle_info({:cleared, target}, socket) do
    {:noreply, update(socket, :waiting, &MapSet.delete(&1, target))}
  end

  def handle_info({:activity, target, activity}, socket) do
    {:noreply, update(socket, :activities, &Map.put(&1, target, activity))}
  end

  defp load_sessions(socket) do
    case Tmux.list_all() do
      {:ok, sessions} ->
        waiting = ClaudeMonitor.waiting_windows()
        activities = ClaudeMonitor.activities()

        assign(socket,
          sessions: sessions,
          waiting: waiting,
          activities: activities,
          loading: false
        )

      {:error, _} ->
        assign(socket, sessions: [], loading: false)
    end
  end

  defp activity_state(target, activities, waiting) do
    is_waiting = MapSet.member?(waiting, target)
    activity = Map.get(activities, target)

    cond do
      is_waiting && activity -> {:waiting, activity}
      is_waiting -> {:waiting, "Needs input"}
      activity -> {:active, activity}
      true -> :idle
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-gray-100">
      <header class="bg-gray-800 border-b border-gray-700 px-4 py-3 flex items-center justify-between">
        <div>
          <div class="flex items-baseline gap-2">
            <h1 class="text-xl font-semibold">Tether</h1>
            <span class="text-xs text-gray-600">v{Application.spec(:tether, :vsn)}</span>
          </div>
          <p class="text-sm text-gray-400">tmux sessions</p>
        </div>
        <button
          id="push-btn"
          phx-hook="PushNotifications"
          phx-update="ignore"
          class="px-3 py-1.5 bg-blue-600 hover:bg-blue-500 text-white text-sm rounded"
        >
          Enable Notifications
        </button>
      </header>

      <main class="p-4">
        <%= if @loading do %>
          <div class="text-gray-400">Loading...</div>
        <% else %>
          <%= if Enum.empty?(@sessions) do %>
            <div class="text-gray-400 text-center py-8">
              <p>No tmux sessions found.</p>
              <p class="text-sm mt-2">
                Start a session with:
                <code class="bg-gray-800 px-2 py-1 rounded">tmux new -s name</code>
              </p>
            </div>
          <% else %>
            <div class="space-y-4">
              <%= for session <- @sessions do %>
                <div class="bg-gray-800 rounded-lg overflow-hidden">
                  <div class="px-4 py-2 bg-gray-700 font-medium flex items-center gap-2">
                    <span>{session.name}</span>
                    <span class="text-gray-400 text-sm">({session.window_count} windows)</span>
                  </div>
                  <ul class="divide-y divide-gray-700">
                    <%= for window <- session.windows do %>
                      <% target = "#{session.name}:#{window.index}" %>
                      <% state = activity_state(target, @activities, @waiting) %>
                      <li>
                        <.link
                          navigate={~p"/terminal/#{session.name}/#{window.index}"}
                          class="block px-4 py-3 hover:bg-gray-700 transition-colors"
                        >
                          <%= if window.is_claude do %>
                            <.claude_row window={window} state={state} />
                          <% else %>
                            <.plain_row window={window} />
                          <% end %>
                        </.link>
                      </li>
                    <% end %>
                  </ul>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </main>
    </div>
    """
  end

  defp claude_row(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <div class="mt-1.5 shrink-0">
        <%= case @state do %>
          <% {:waiting, _} -> %>
            <span class="block w-2 h-2 rounded-full bg-yellow-400 animate-pulse"></span>
          <% {:active, _} -> %>
            <span class="block w-2 h-2 rounded-full bg-green-400 animate-pulse"></span>
          <% :idle -> %>
            <span class="block w-2 h-2 rounded-full bg-gray-600"></span>
        <% end %>
      </div>
      <div class="min-w-0 flex-1">
        <%= case @state do %>
          <% {:waiting, text} -> %>
            <div class="text-yellow-400 font-medium truncate">{text}</div>
            <div class="text-xs text-yellow-400/60">{@window.name}</div>
          <% {:active, text} -> %>
            <div class="text-gray-200 truncate">{text}</div>
            <div class="text-xs text-gray-500">{@window.name}</div>
          <% :idle -> %>
            <div class="text-gray-400">{@window.name}</div>
        <% end %>
      </div>
    </div>
    """
  end

  defp plain_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <span class="text-gray-400">{@window.name}</span>
      <span class="text-xs px-2 py-0.5 rounded bg-gray-700 text-gray-500">{@window.command}</span>
    </div>
    """
  end
end
