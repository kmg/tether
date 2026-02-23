defmodule TetherWeb.TerminalLive do
  @moduledoc """
  Terminal view - xterm.js connected to a tmux window via PTY.

  Architecture: Single render path via PTY attachment.
  - No lite mode preview (removed to simplify and avoid race conditions)
  - Client connects → PTY attaches to tmux → output streamed via WebSocket
  - If latency is truly unbearable, use mosh instead
  """
  use TetherWeb, :live_view

  alias Tether.{WindowSession, ClaudeMonitor}

  # Loading stages: :connecting -> :pty_starting -> :terminal_init -> :streaming -> :ready
  def mount(%{"session" => session, "window" => window}, _session, socket) do
    target = "#{session}:#{window}"

    # Determine initial loading stage based on socket connection
    loading_stage = if connected?(socket), do: :pty_starting, else: :connecting

    socket =
      socket
      |> assign(
        session: session,
        window: window,
        target: target,
        connected: false,
        session_pid: nil,
        select_mode: false,
        loading_stage: loading_stage,
        bytes_received: 0
      )

    if connected?(socket) do
      send(self(), :connect_terminal)
      send(self(), :ping)
      # Subscribe to Claude waiting notifications for this target
      Phoenix.PubSub.subscribe(Tether.PubSub, "claude_monitor")
    end

    {:ok, socket}
  end

  def handle_info(:connect_terminal, socket) do
    target = socket.assigns.target

    # Start the PTY session (no lite mode preview - single render path)
    case WindowSession.start_link(target) do
      {:ok, pid} ->
        Process.monitor(pid)
        # Don't subscribe yet - wait for terminal_ready
        ClaudeMonitor.register_active(target)

        {:noreply,
         assign(socket, connected: true, session_pid: pid, loading_stage: :terminal_init)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to connect: #{inspect(reason)}")
         |> push_navigate(to: ~p"/")}
    end
  end

  # Threshold for "first screen loaded" - typical terminal with ANSI codes
  @first_screen_bytes 5_000

  def handle_info({:terminal_output, data}, socket) do
    # Only update loading assigns until terminal is ready — after that, skip assign updates
    # to avoid any server-side re-evaluation (assigns inside phx-update="ignore" don't patch
    # the DOM anyway, but updating them still costs a template re-eval)
    socket =
      if socket.assigns.loading_stage == :ready do
        socket
      else
        bytes_received = socket.assigns.bytes_received + byte_size(data)

        loading_stage =
          if bytes_received >= @first_screen_bytes, do: :ready, else: socket.assigns.loading_stage

        assign(socket, bytes_received: bytes_received, loading_stage: loading_stage)
      end

    {:noreply, push_event(socket, "terminal_output", %{data: Base.encode64(data)})}
  end

  # Claude waiting notification (for push notifications, not TTS)
  def handle_info({:waiting, _window}, socket) do
    {:noreply, socket}
  end

  def handle_info({:cleared, _target}, socket) do
    {:noreply, socket}
  end

  # Activity updates are for HomeLive's session list, not the terminal view
  def handle_info({:activity, _target, _activity}, socket) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    if pid == socket.assigns.session_pid do
      {:noreply,
       socket
       |> assign(connected: false, session_pid: nil)
       |> put_flash(:info, "Session ended")
       |> push_navigate(to: ~p"/")}
    else
      {:noreply, socket}
    end
  end

  # Latency measurement
  def handle_info(:ping, socket) do
    Process.send_after(self(), :ping, 3000)
    {:noreply, push_event(socket, "ping", %{ts: System.monotonic_time(:millisecond)})}
  end

  def handle_event("terminal_input", %{"data" => data}, socket) do
    if socket.assigns.session_pid do
      decoded = Base.decode64!(data)
      WindowSession.send_input(socket.assigns.session_pid, decoded)
    end

    {:noreply, socket}
  end

  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows}, socket) do
    if socket.assigns.session_pid do
      WindowSession.resize(socket.assigns.session_pid, cols, rows)
    end

    {:noreply, socket}
  end

  # Client signals it's ready to receive output - now subscribe and trigger redraw
  def handle_event("terminal_ready", %{"cols" => cols, "rows" => rows}, socket) do
    if socket.assigns.session_pid do
      # NOW subscribe - client is ready to receive
      WindowSession.subscribe(socket.assigns.session_pid)
      # Resize triggers tmux to redraw
      WindowSession.resize(socket.assigns.session_pid, cols, rows)
      # Force refresh in case size is unchanged (e.g., LiveView reconnect after background)
      WindowSession.force_refresh(socket.assigns.session_pid)
    end

    {:noreply, assign(socket, loading_stage: :streaming)}
  end

  def handle_event("request_refresh", _params, socket) do
    if socket.assigns.session_pid do
      WindowSession.force_refresh(socket.assigns.session_pid)
    end

    {:noreply, socket}
  end

  # Special key mappings for mobile toolbar
  @key_sequences %{
    "enter" => "\r",
    "escape" => "\e",
    "tab" => "\t",
    "shift_tab" => "\e[Z",
    "up" => "\e[A",
    "down" => "\e[B",
    "right" => "\e[C",
    "left" => "\e[D",
    "ctrl_c" => "\x03",
    "ctrl_d" => "\x04",
    "ctrl_z" => "\x1a",
    "page_up" => "\e[5~",
    "page_down" => "\e[6~",
    # Ctrl+A then [ to enter tmux copy mode
    "tmux_scroll" => "\x01["
  }

  def handle_event("send_key", %{"key" => key}, socket) do
    if socket.assigns.session_pid do
      case Map.get(@key_sequences, key) do
        nil -> :ok
        seq -> WindowSession.send_input(socket.assigns.session_pid, seq)
      end
    end

    {:noreply, socket}
  end

  # MIME type to file extension mapping
  @mime_extensions %{
    # Images
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp",
    # Documents
    "application/pdf" => "pdf",
    "application/msword" => "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
    "application/vnd.ms-excel" => "xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "application/vnd.ms-powerpoint" => "ppt",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => "pptx",
    # Text
    "text/plain" => "txt",
    "text/markdown" => "md",
    "text/x-markdown" => "md",
    "application/octet-stream" => "bin"
  }

  def handle_event("paste_file", %{"data" => data, "type" => type} = params, socket) do
    if socket.assigns.session_pid do
      # Try filename extension first, then MIME type, then fallback to bin
      ext =
        case params["name"] do
          nil ->
            Map.get(@mime_extensions, type, "bin")

          name ->
            case Path.extname(name) do
              "." <> ext -> ext
              _ -> Map.get(@mime_extensions, type, "bin")
            end
        end

      # Save to temp file
      filename = "paste-#{System.system_time(:millisecond)}.#{ext}"
      path = Path.join(System.tmp_dir!(), filename)

      case Base.decode64(data) do
        {:ok, binary} ->
          File.write!(path, binary)
          # Insert the file path into terminal
          WindowSession.send_input(socket.assigns.session_pid, path)

        :error ->
          :ok
      end
    end

    {:noreply, socket}
  end

  # Keep old handler for backwards compatibility
  def handle_event("paste_image", params, socket) do
    handle_event("paste_file", params, socket)
  end

  def handle_event("toggle_select_mode", _params, socket) do
    new_mode = !socket.assigns.select_mode

    socket =
      socket
      |> assign(select_mode: new_mode)
      |> push_event("toggle_select_mode", %{enabled: new_mode})

    {:noreply, socket}
  end

  def handle_event("pong", %{"ts" => ts}, socket) do
    now = System.monotonic_time(:millisecond)
    round_trip = now - ts

    # Store pings in process dictionary to avoid assign updates that trigger re-renders.
    # Re-renders cause DOM patches in the header, which on mobile Safari can steal focus
    # from xterm's hidden textarea, dropping keystrokes mid-typing.
    pings = Enum.take([round_trip | Process.get(:pings, [])], 5)
    Process.put(:pings, pings)
    avg = (Enum.sum(pings) / length(pings)) |> round()

    {:noreply, push_event(socket, "latency_update", %{avg: avg})}
  end

  def terminate(_reason, socket) do
    # Unregister when leaving (re-enables notifications)
    ClaudeMonitor.unregister_active(socket.assigns.target)
    :ok
  end

  defp loading_milestone(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <%= if @done do %>
        <span class="text-green-500">✓</span>
        <span class="text-gray-400">{@label}</span>
      <% else %>
        <span class="text-yellow-500 animate-pulse">◐</span>
        <span class="text-gray-300">{@label}</span>
      <% end %>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="h-dvh flex flex-col bg-black">
      <header class="bg-gray-800 border-b border-gray-700 px-4 py-2 flex items-center justify-between shrink-0">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/"} class="text-gray-400 hover:text-white">
            ← Back
          </.link>
          <span class="text-gray-100 font-medium">{@session}</span>
          <span class="text-gray-400">→</span>
          <span class="text-gray-300">{@window}</span>
        </div>
        <div class="flex items-center gap-2 text-xs text-gray-500">
          <span id="latency-display"></span>
          <%= if @connected do %>
            <span class="w-1.5 h-1.5 bg-green-600 rounded-full"></span>
          <% else %>
            <span class="w-1.5 h-1.5 bg-yellow-600 rounded-full animate-pulse"></span>
          <% end %>
        </div>
      </header>

      <main
        id="terminal-container"
        class="flex-1 overflow-hidden relative"
        phx-hook="Terminal"
        phx-update="ignore"
      >
        <%!-- Loading overlay - hidden by JS when terminal renders --%>
        <div
          id="loading-overlay"
          class="absolute inset-0 bg-black flex flex-col items-center justify-center z-10"
        >
          <div class="font-mono text-sm space-y-1">
            <.loading_milestone done={@loading_stage not in [:connecting]} label="Server" />
            <.loading_milestone
              done={@loading_stage not in [:connecting, :pty_starting]}
              label="Session"
            />
            <.loading_milestone done={@loading_stage in [:streaming, :ready]} label="Display" />
            <%= if @loading_stage in [:streaming, :ready] do %>
              <div class="text-gray-500 pt-2">
                {Float.round(@bytes_received / 1024, 1)} KB received
              </div>
            <% end %>
          </div>
        </div>
      </main>

      <%!-- Mobile toolbar - two rows: meta actions + keyboard --%>
      <div class="bg-gray-900 border-t border-gray-700 shrink-0" id="key-toolbar">
        <%!-- Row 1: Meta/utility actions --%>
        <div class="px-2 py-1 flex gap-1 overflow-x-auto border-b border-gray-800">
          <button
            type="button"
            phx-click="toggle_select_mode"
            class={"px-3 py-1.5 text-gray-200 text-sm rounded " <> if(@select_mode, do: "bg-gray-600", else: "bg-gray-700 hover:bg-gray-600")}
          >
            {if @select_mode, do: "Done", else: "Select"}
          </button>
          <%= if @select_mode do %>
            <button
              type="button"
              phx-click={JS.dispatch("terminal:copy")}
              class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
            >
              Copy
            </button>
          <% end %>
          <button
            type="button"
            phx-click={JS.dispatch("terminal:paste")}
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            Paste
          </button>
          <label class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded cursor-pointer">
            Attach
            <input
              type="file"
              accept="image/*,.pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.md,.txt"
              class="hidden"
              phx-hook="FileUpload"
              id="file-upload"
            />
          </label>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="tmux_scroll"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            Scroll
          </button>
          <button
            type="button"
            phx-click={JS.dispatch("terminal:refresh")}
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            Refresh
          </button>
        </div>
        <%!-- Row 2: Keyboard keys --%>
        <div class="px-2 py-1 flex gap-1 overflow-x-auto">
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="enter"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            Enter
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="escape"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            Esc
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="tab"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            Tab
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="up"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            ↑
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="down"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            ↓
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="left"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            ←
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="right"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            →
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="ctrl_c"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            ^C
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="ctrl_d"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            ^D
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="ctrl_z"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            ^Z
          </button>
          <button
            type="button"
            phx-click="send_key"
            phx-value-key="shift_tab"
            class="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-gray-200 text-sm rounded"
          >
            ⇧Tab
          </button>
        </div>
      </div>
    </div>
    """
  end
end
