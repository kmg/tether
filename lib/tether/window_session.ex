defmodule Tether.WindowSession do
  @moduledoc """
  GenServer that manages a PTY connection to a tmux window.
  Handles bidirectional I/O between the web client and tmux.
  """
  use GenServer
  require Logger

  # Buffer output before sending to reduce packet count
  # Higher value = fewer packets but more latency
  @flush_interval 100

  defstruct [:target, :port, :exec_pid, subscribers: [], buffer: "", flush_ref: nil, cols: 80, rows: 24]

  @doc """
  Start a session attached to a tmux window.
  target is "session:window_index"
  """
  def start_link(target) do
    GenServer.start_link(__MODULE__, target)
  end

  @doc """
  Send input to the terminal.
  """
  def send_input(pid, data) do
    GenServer.cast(pid, {:input, data})
  end

  @doc """
  Subscribe to terminal output.
  """
  def subscribe(pid) do
    GenServer.call(pid, {:subscribe, self()})
  end

  @doc """
  Unsubscribe from terminal output.
  """
  def unsubscribe(pid) do
    GenServer.cast(pid, {:unsubscribe, self()})
  end

  @doc """
  Resize the terminal.
  """
  def resize(pid, cols, rows) do
    GenServer.cast(pid, {:resize, cols, rows})
  end

  @doc """
  Force tmux to redraw by briefly changing the PTY size, then restoring it.
  Used when returning from iOS background where a same-size resize is a no-op.
  """
  def force_refresh(pid) do
    GenServer.cast(pid, :force_refresh)
  end

  # Server callbacks

  def init(target) do
    Process.flag(:trap_exit, true)

    case start_tmux_attach(target) do
      {:ok, port, exec_pid} ->
        Logger.info("WindowSession started for #{target}")
        {:ok, %__MODULE__{target: target, port: port, exec_pid: exec_pid}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_cast({:input, data}, state) do
    if state.exec_pid do
      # Log inputs longer than typical keypresses for debugging
      if byte_size(data) > 10 do
        Logger.debug(
          "WindowSession input (#{byte_size(data)} bytes): #{inspect(data, limit: 100)}"
        )
      end

      :exec.send(state.exec_pid, data)
    end

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_cast({:resize, cols, rows}, state) do
    if state.exec_pid do
      :exec.winsz(state.exec_pid, rows, cols)
    end

    {:noreply, %{state | cols: cols, rows: rows}}
  end

  def handle_cast(:force_refresh, state) do
    if state.exec_pid && state.rows > 1 do
      :exec.winsz(state.exec_pid, state.rows - 1, state.cols)
      Process.send_after(self(), :restore_size, 50)
    end

    {:noreply, state}
  end

  # Handle output from the PTY - buffer before sending
  def handle_info({:stdout, _pid, data}, state) do
    state = %{state | buffer: state.buffer <> data}
    state = schedule_flush(state)
    {:noreply, state}
  end

  def handle_info({:stderr, _pid, data}, state) do
    state = %{state | buffer: state.buffer <> data}
    state = schedule_flush(state)
    {:noreply, state}
  end

  # Flush buffered output to subscribers
  def handle_info(:flush, state) do
    if state.buffer != "" do
      size = byte_size(state.buffer)

      if size > 100 do
        Logger.info("WindowSession #{state.target} sending #{size} bytes")
      end

      broadcast_output(state.subscribers, state.buffer)
    end

    {:noreply, %{state | buffer: "", flush_ref: nil}}
  end

  # Restore PTY size after force_refresh trick
  def handle_info(:restore_size, state) do
    if state.exec_pid do
      :exec.winsz(state.exec_pid, state.rows, state.cols)
    end

    {:noreply, state}
  end

  # Handle process exit
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.info("WindowSession #{state.target} exited: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_info(msg, state) do
    Logger.debug("WindowSession received: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(_reason, state) do
    # Flush any remaining buffered output
    if state.buffer != "" do
      broadcast_output(state.subscribers, state.buffer)
    end

    if state.exec_pid do
      :exec.stop(state.exec_pid)
    end

    :ok
  end

  # Private functions

  defp start_tmux_attach(target) do
    # Use erlexec to spawn tmux attach with PTY
    # Set UTF-8 locale to ensure proper character encoding
    # target is "session:window" - tmux attach handles this format
    cmd = "tmux attach-session -t #{target}"

    opts = [
      :stdin,
      :stdout,
      :stderr,
      :pty,
      :monitor,
      env: [
        {~c"LANG", ~c"en_US.UTF-8"},
        {~c"LC_ALL", ~c"en_US.UTF-8"},
        {~c"TERM", ~c"xterm-256color"}
      ]
    ]

    case :exec.run(cmd, opts) do
      {:ok, pid, os_pid} ->
        Logger.debug("Started tmux attach: pid=#{inspect(pid)}, os_pid=#{os_pid}")
        {:ok, nil, pid}

      {:error, reason} ->
        Logger.error("Failed to start tmux attach: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp broadcast_output(subscribers, data) do
    for pid <- subscribers do
      send(pid, {:terminal_output, data})
    end
  end

  # Schedule a flush if not already scheduled
  defp schedule_flush(%{flush_ref: nil} = state) do
    ref = Process.send_after(self(), :flush, @flush_interval)
    %{state | flush_ref: ref}
  end

  defp schedule_flush(state), do: state
end
