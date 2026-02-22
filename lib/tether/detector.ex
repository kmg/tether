defmodule Tether.Detector do
  @moduledoc """
  Detects when Claude Code or other AI agents are waiting for input.
  """

  @default_patterns [
    # Claude Code permission prompts
    ~r/Allow|Deny|Approve|Reject/i,
    ~r/\[y\/n\]/i,
    ~r/\[Y\/n\]/,
    ~r/\[yes\/no\]/i,
    ~r/Do you want to proceed/i,

    # Claude waiting indicators
    ~r/waiting for your response/i,
    ~r/Waiting for input/i,

    # Generic input prompts
    ~r/Press Enter|Press any key/i,
    ~r/Continue\?/i
  ]

  @doc """
  Check if the given text contains patterns indicating the agent is waiting for input.
  Returns {:waiting, pattern_matched} or :ok
  """
  def check(text, patterns \\ @default_patterns) do
    # Look at the last few lines where prompts typically appear
    last_lines =
      text
      |> String.split("\n")
      |> Enum.take(-10)
      |> Enum.join("\n")

    case Enum.find(patterns, &Regex.match?(&1, last_lines)) do
      nil -> :ok
      pattern -> {:waiting, Regex.source(pattern)}
    end
  end

  @doc """
  Get the default patterns.
  """
  def default_patterns, do: @default_patterns
end
