defmodule Tether.Tmux do
  @moduledoc """
  Interface to tmux commands for listing sessions/windows and capturing pane content.
  """

  @doc """
  List all tmux sessions with their window count.
  Returns [{session_name, window_count}, ...]
  """
  def list_sessions do
    case System.cmd("tmux", ["list-sessions", "-F", "\#{session_name}:\#{session_windows}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        sessions =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_session/1)

        {:ok, sessions}

      {error, _} ->
        if String.contains?(error, "no server running") do
          {:ok, []}
        else
          {:error, error}
        end
    end
  end

  defp parse_session(line) do
    case String.split(line, ":", parts: 2) do
      [name, count] -> %{name: name, window_count: String.to_integer(count)}
      _ -> %{name: line, window_count: 0}
    end
  end

  @doc """
  List all windows in a session.
  Returns [%{index: int, name: string, command: string}, ...]
  """
  def list_windows(session_name) do
    case System.cmd(
           "tmux",
           [
             "list-windows",
             "-t",
             session_name,
             "-F",
             "\#{window_index}:\#{window_name}:\#{pane_current_command}"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        windows =
          output
          |> String.trim()
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_window/1)

        {:ok, windows}

      {error, _} ->
        {:error, error}
    end
  end

  defp parse_window(line) do
    case String.split(line, ":", parts: 3) do
      [index, name, command] ->
        %{
          index: String.to_integer(index),
          name: name,
          command: command,
          is_claude: String.contains?(String.downcase(command), "claude")
        }

      _ ->
        %{index: 0, name: line, command: "", is_claude: false}
    end
  end

  @doc """
  Capture the last N lines from a pane.
  Options:
    - escape_sequences: include ANSI escape codes (default: true for styled preview)
  """
  def capture_pane(session, window_index, lines \\ 50, opts \\ []) do
    target = "#{session}:#{window_index}"
    include_escapes = Keyword.get(opts, :escape_sequences, true)

    # -e includes escape sequences (colors, styling)
    # -p prints to stdout
    # -S -N captures last N lines
    args =
      if include_escapes do
        ["capture-pane", "-t", target, "-p", "-e", "-S", "-#{lines}"]
      else
        ["capture-pane", "-t", target, "-p", "-S", "-#{lines}"]
      end

    case System.cmd("tmux", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, error}
    end
  end

  @doc """
  Get all sessions with their windows in one call.
  """
  def list_all do
    with {:ok, sessions} <- list_sessions() do
      sessions_with_windows =
        Enum.map(sessions, fn session ->
          case list_windows(session.name) do
            {:ok, windows} -> Map.put(session, :windows, windows)
            {:error, _} -> Map.put(session, :windows, [])
          end
        end)

      {:ok, sessions_with_windows}
    end
  end

  @doc """
  Find all windows running Claude across all sessions.
  Returns [{session_name, window_index, window_name}, ...]
  """
  def find_claude_windows do
    case list_all() do
      {:ok, sessions} ->
        claude_windows =
          for session <- sessions,
              window <- session.windows,
              window.is_claude do
            %{
              session: session.name,
              index: window.index,
              name: window.name,
              target: "#{session.name}:#{window.index}"
            }
          end

        {:ok, claude_windows}

      error ->
        error
    end
  end
end
