defmodule Tether.ActivityParser do
  @moduledoc """
  Extracts a one-line activity summary from Claude Code's terminal output.
  Parses plain-text tmux capture-pane content (no ANSI escape sequences).

  Shows meaningful activity: the user's prompt (what was asked), the active
  tool call (what Claude is doing), or the permission being requested.
  """

  # Tool call line
  @tool_names ~w(Bash Read Edit Write Grep Glob Task WebFetch WebSearch NotebookEdit)
  @tool_call_re ~r/⏺\s+(Bash|Read|Edit|Write|Grep|Glob|Task|WebFetch|WebSearch|NotebookEdit)\s*[\(:\(]/
  # Tool response (completed)
  @response_re ~r/^\s+⎿/
  # Running indicator
  @running_re ~r/^\s+Running/
  # Permission prompt
  @permission_re ~r/Do you want to proceed/
  # Separator line
  @separator_re ~r/^[─━]+$/
  # Status bar (bottom boundary marker)
  @status_bar_re ~r/\[(Opus|Sonnet|Haiku)\s+[\d.]+\]\s+\d+%/
  # User prompt with text (Claude Code uses \u00A0 non-breaking space after ❯)
  @prompt_with_text_re ~r/^❯[\s\x{00A0}]+(.+)/u
  # Empty user prompt
  @prompt_empty_re ~r/^❯[\s\x{00A0}]*$/u
  # Active thinking spinner
  @thinking_re ~r/^·\s+\w/
  # Just finished thinking
  @thought_done_re ~r/^✻\s+\w+.*for\s+\d/

  @doc """
  Parse captured pane content into an activity summary.

  Returns one of:
    - `{:waiting, prompt_text}` — waiting for permission/input
    - `{:tool, tool_name, detail}` — actively using a tool
    - `{:working, user_prompt}` — Claude is working on user's request
    - `{:idle, nil}` — at user prompt, ready for input
    - `nil` — couldn't determine activity
  """
  def parse(nil), do: nil
  def parse(""), do: nil

  def parse(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)

    {_status_bar, body_lines} = split_status_bar(lines)

    # First, find the user's last prompt — this is the "task description"
    last_prompt = find_last_user_prompt(body_lines)

    # Then scan bottom-up for current state
    scan_bottom_up(Enum.reverse(body_lines), last_prompt)
  end

  @doc """
  Convert parsed activity to a display string suitable for the home screen.
  """
  def to_display_string(nil), do: nil
  def to_display_string({:waiting, prompt}), do: prompt
  def to_display_string({:tool, name, detail}), do: format_tool(name, detail)
  def to_display_string({:working, prompt}), do: truncate(prompt, 60)
  def to_display_string({:idle, nil}), do: nil

  # --- Find user's last prompt ---

  defp find_last_user_prompt(lines) do
    # Scan all lines to find the last ❯ with text (the most recent user input)
    lines
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      trimmed = String.trim(line)

      case Regex.run(@prompt_with_text_re, trimmed) do
        [_, text] ->
          # Clean up the prompt text: join wrapped lines would be nice
          # but single line is good enough for a preview
          clean = text |> String.trim() |> String.replace(~r/\s+/, " ")
          if clean != "", do: clean, else: nil

        _ ->
          nil
      end
    end)
  end

  # --- Bottom-up scanner ---

  defp scan_bottom_up([], _prompt), do: nil

  defp scan_bottom_up([line | rest], prompt) do
    trimmed = String.trim(line)

    cond do
      # Skip empty lines and separators
      trimmed == "" or Regex.match?(@separator_re, trimmed) ->
        scan_bottom_up(rest, prompt)

      # Active thinking spinner
      Regex.match?(@thinking_re, trimmed) ->
        working_on(prompt)

      # Just finished thinking — Claude about to respond
      Regex.match?(@thought_done_re, trimmed) ->
        working_on(prompt)

      # Empty prompt (❯) — look above to see if Claude is actively working
      Regex.match?(@prompt_empty_re, trimmed) ->
        check_above_prompt(rest, prompt)

      # Prompt with text — this is the input area; look above for state
      Regex.match?(@prompt_with_text_re, trimmed) ->
        check_above_prompt(rest, prompt)

      # Permission prompt
      Regex.match?(@permission_re, trimmed) ->
        find_permission_context(rest)

      # "Running" indicator = tool actively executing
      Regex.match?(@running_re, line) ->
        find_tool_above(rest)

      # Response line (⎿) = a tool just completed, keep scanning
      Regex.match?(@response_re, line) ->
        skip_to_completed_tool_then_continue(rest, prompt)

      # Tool call line with NO response below = actively running
      Regex.match?(@tool_call_re, line) ->
        case parse_tool_line(line) do
          nil -> scan_bottom_up(rest, prompt)
          tool -> {:tool, tool.name, tool.detail}
        end

      # Claude text output (⏺ non-tool) = Claude is responding
      String.starts_with?(trimmed, "⏺") ->
        working_on(prompt)

      # Other content — keep scanning
      true ->
        scan_bottom_up(rest, prompt)
    end
  end

  # Return {:working, prompt} if we have a prompt, else nil
  defp working_on(nil), do: nil
  defp working_on(prompt), do: {:working, prompt}

  # When we hit a ❯ prompt, look above to see if Claude is actively working
  defp check_above_prompt(lines, prompt) do
    lines
    |> Enum.reject(fn l ->
      t = String.trim(l)
      t == "" or Regex.match?(@separator_re, t)
    end)
    |> case do
      [] ->
        {:idle, nil}

      [first | _] ->
        trimmed = String.trim(first)

        cond do
          Regex.match?(@thinking_re, trimmed) -> working_on(prompt)
          Regex.match?(@thought_done_re, trimmed) -> working_on(prompt)
          String.starts_with?(trimmed, "⏺") -> working_on(prompt)
          true -> {:idle, nil}
        end
    end
  end

  # After seeing a response (⎿), skip up past the tool call
  defp skip_to_completed_tool_then_continue([], _prompt), do: nil

  defp skip_to_completed_tool_then_continue([line | rest], prompt) do
    if Regex.match?(@tool_call_re, line) do
      scan_bottom_up(rest, prompt)
    else
      skip_to_completed_tool_then_continue(rest, prompt)
    end
  end

  defp find_permission_context(lines) do
    case find_tool_above(lines) do
      {:tool, name, _detail} -> {:waiting, "Allow #{name}?"}
      _ -> {:waiting, "Waiting for permission"}
    end
  end

  defp find_tool_above([]), do: nil

  defp find_tool_above([line | rest]) do
    if Regex.match?(@tool_call_re, line) do
      case parse_tool_line(line) do
        nil -> find_tool_above(rest)
        tool -> {:tool, tool.name, tool.detail}
      end
    else
      find_tool_above(rest)
    end
  end

  # --- Status bar ---

  defp split_status_bar(lines) do
    reversed = Enum.reverse(lines)

    case Enum.find_index(reversed, &Regex.match?(@status_bar_re, &1)) do
      nil -> {nil, lines}
      idx ->
        status_line = Enum.at(reversed, idx)
        body = reversed |> Enum.drop(idx + 1) |> Enum.reverse()
        {status_line, body}
    end
  end

  # --- Tool line parsing ---

  defp parse_tool_line(line) do
    case Regex.run(~r/⏺\s+(\w+)\((.*)/, line) do
      [_, name, args] when name in @tool_names ->
        detail = args |> String.trim_trailing(")") |> truncate(60)
        %{name: name, detail: detail}

      _ ->
        case Regex.run(~r/⏺\s+(\w+):\s*(.*)/, line) do
          [_, name, desc] when name in @tool_names ->
            %{name: name, detail: truncate(desc, 60)}
          _ -> nil
        end
    end
  end

  # --- Display formatting ---

  defp format_tool("Bash", detail) do
    cmd = detail |> String.split("\n") |> hd() |> String.trim()
    "Running: #{truncate(cmd, 50)}"
  end

  defp format_tool("Read", detail), do: "Reading #{extract_filename(detail)}"
  defp format_tool("Edit", detail), do: "Editing #{extract_filename(detail)}"
  defp format_tool("Write", detail), do: "Writing #{extract_filename(detail)}"
  defp format_tool("Grep", detail), do: "Searching: #{truncate(detail, 50)}"
  defp format_tool("Glob", detail), do: "Finding files: #{truncate(detail, 50)}"
  defp format_tool("Task", detail), do: "Running task: #{truncate(detail, 50)}"
  defp format_tool("WebFetch", detail), do: "Fetching: #{truncate(detail, 50)}"
  defp format_tool("WebSearch", detail), do: "Searching web: #{truncate(detail, 50)}"
  defp format_tool(name, detail), do: "#{name}: #{truncate(detail, 50)}"

  defp extract_filename(path) do
    path
    |> String.split("/")
    |> List.last()
    |> String.trim_trailing(")")
    |> truncate(40)
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max - 1) <> "…"
    else
      str
    end
  end
end
