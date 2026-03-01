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
     |> assign(
       sessions: [],
       waiting: MapSet.new(),
       activities: %{},
       loading: true,
       show_new_session: false,
       new_session_form: to_form(%{"name" => "", "windows" => "4"}, as: :session)
     )
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

  def handle_event("toggle_new_session", _params, socket) do
    {:noreply, assign(socket, show_new_session: !socket.assigns.show_new_session)}
  end

  def handle_event("add_window", %{"session" => session}, socket) do
    case Tmux.new_window(session) do
      {:ok, index} ->
        {:noreply,
         socket
         |> load_sessions()
         |> push_navigate(to: ~p"/terminal/#{session}/#{index}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event(
        "create_session",
        %{"session" => %{"name" => name, "windows" => windows_str}},
        socket
      ) do
    name = String.trim(name)
    window_count = max(String.to_integer(windows_str), 1)

    case Tmux.new_session(name) do
      {:ok, _} ->
        Enum.each(2..window_count//1, fn _ -> Tmux.new_window(name) end)

        {:noreply,
         socket
         |> assign(show_new_session: false)
         |> assign(new_session_form: to_form(%{"name" => "", "windows" => "4"}, as: :session))
         |> load_sessions()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
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
    <div
      class="bg-gray-900 text-gray-100"
      style="position:fixed;inset:0;overflow-y:auto;-webkit-overflow-scrolling:touch"
    >
      <header class="bg-gray-800 border-b border-gray-700 px-4 py-3 flex items-center justify-between">
        <div class="flex items-baseline gap-2">
          <h1 class="text-lg font-semibold">Tether</h1>
          <span class="text-xs text-gray-600">v{Application.spec(:tether, :vsn)}</span>
        </div>
        <div class="flex items-center gap-3">
          <button
            id="push-btn"
            phx-hook="PushNotifications"
            phx-update="ignore"
            style="display:flex;flex-direction:column;align-items:center;gap:2px;color:#6b7280;width:40px"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              stroke-width="1.5"
              stroke="currentColor"
              style="width:16px;height:16px"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M14.857 17.082a23.848 23.848 0 0 0 5.454-1.31A8.967 8.967 0 0 1 18 9.75V9A6 6 0 0 0 6 9v.75a8.967 8.967 0 0 1-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 0 1-5.714 0m5.714 0a3 3 0 1 1-5.714 0"
              />
            </svg>
            <span style="font-size:10px;line-height:1">Notify</span>
          </button>
          <button
            phx-click="toggle_new_session"
            style="display:flex;flex-direction:column;align-items:center;gap:2px;color:#6b7280;width:40px"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              stroke-width="1.5"
              stroke="currentColor"
              style="width:16px;height:16px"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
            </svg>
            <span style="font-size:10px;line-height:1">Session</span>
          </button>
        </div>
      </header>

      <%= if @show_new_session do %>
        <div class="bg-gray-800 border-b border-gray-700 px-4 py-3">
          <.form
            for={@new_session_form}
            id="new-session-form"
            phx-submit="create_session"
            class="space-y-3"
          >
            <div class="flex gap-3">
              <div class="flex-1">
                <label class="block text-xs text-gray-400 mb-1">Session name</label>
                <input
                  type="text"
                  name="session[name]"
                  value={@new_session_form[:name].value}
                  placeholder="work"
                  required
                  pattern="[a-zA-Z0-9_-]+"
                  class="w-full bg-gray-900 border border-gray-600 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-green-500 focus:outline-none"
                />
              </div>
              <div class="w-20">
                <label class="block text-xs text-gray-400 mb-1">Windows</label>
                <input
                  type="number"
                  name="session[windows]"
                  value={@new_session_form[:windows].value}
                  min="1"
                  max="20"
                  class="w-full bg-gray-900 border border-gray-600 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-green-500 focus:outline-none"
                />
              </div>
            </div>
            <div class="flex gap-2">
              <button
                type="submit"
                class="flex-1 py-1.5 bg-green-700 hover:bg-green-600 text-white text-sm rounded"
              >
                Create
              </button>
              <button
                type="button"
                phx-click="toggle_new_session"
                class="px-4 py-1.5 text-gray-400 hover:text-gray-200 text-sm"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>
      <% end %>

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
                  <div class="px-4 py-2 bg-gray-700 font-medium flex items-center justify-between">
                    <div class="flex items-center gap-2">
                      <span>{session.name}</span>
                      <span class="text-gray-400 text-sm">({session.window_count} windows)</span>
                    </div>
                    <button
                      phx-click="add_window"
                      phx-value-session={session.name}
                      class="text-gray-400 hover:text-green-400 text-sm"
                    >
                      +
                    </button>
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
      <div class="shrink-0 text-gray-600 self-center">›</div>
    </div>
    """
  end

  defp plain_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3">
      <span class="text-gray-400 flex-1">{@window.name}</span>
      <span class="text-xs px-2 py-0.5 rounded bg-gray-700 text-gray-500">{@window.command}</span>
      <span class="shrink-0 text-gray-600">›</span>
    </div>
    """
  end
end
