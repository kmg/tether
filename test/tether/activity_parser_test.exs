defmodule Tether.ActivityParserTest do
  use ExUnit.Case, async: true

  alias Tether.ActivityParser

  # Helper to build terminal content with a status bar at the bottom
  defp with_status_bar(lines) do
    body = Enum.join(lines, "\n")
    body <> "\n[Opus 4.6] 45%  7.1k tokens remaining"
  end

  describe "parse/1" do
    test "nil and empty content" do
      assert ActivityParser.parse(nil) == nil
      assert ActivityParser.parse("") == nil
    end

    test "permission prompt returns {:waiting, _}" do
      content =
        with_status_bar([
          "❯\u00A0fix the login bug",
          "",
          "⏺ Bash(rm -rf /tmp/test)",
          "",
          "  Do you want to proceed?",
          ""
        ])

      assert {:waiting, "Allow Bash?"} = ActivityParser.parse(content)
    end

    test "empty prompt returns {:idle, _} with last prompt as context" do
      content =
        with_status_bar([
          "❯\u00A0fix the login bug",
          "",
          "⏺ I've fixed the login bug by updating the auth module.",
          "",
          "❯\u00A0",
          ""
        ])

      assert {:idle, "fix the login bug"} = ActivityParser.parse(content)
    end

    test "idle prompt with stale Allow text in history — the false positive bug case" do
      # This is the exact scenario that Detector got wrong:
      # An old permission prompt was answered, Claude finished, and is now idle.
      # The word "Allow" still appears in terminal history.
      content =
        with_status_bar([
          "❯\u00A0deploy the app",
          "",
          "⏺ Bash(./deploy.sh)",
          "",
          "  Do you want to proceed?",
          "",
          "  ⎿ Allowed",
          "",
          "  ⎿ Deployed successfully",
          "",
          "⏺ I've deployed the app.",
          "",
          "❯\u00A0",
          ""
        ])

      # ActivityParser should see the empty ❯ at the bottom and return idle,
      # NOT be fooled by the stale "Allow" / "Do you want to proceed" text
      assert {:idle, "deploy the app"} = ActivityParser.parse(content)
    end

    test "active tool call returns {:tool, name, detail}" do
      content =
        with_status_bar([
          "❯\u00A0refactor the module",
          "",
          "⏺ Read(lib/my_app/server.ex)",
          ""
        ])

      assert {:tool, "Read", _detail} = ActivityParser.parse(content)
    end

    test "thinking spinner returns {:working, prompt}" do
      content =
        with_status_bar([
          "❯\u00A0explain this code",
          "",
          "· Thinking about the code structure",
          ""
        ])

      assert {:working, "explain this code"} = ActivityParser.parse(content)
    end

    test "thought done marker returns {:working, prompt}" do
      content =
        with_status_bar([
          "❯\u00A0explain this code",
          "",
          "✻ Thought for 3s",
          ""
        ])

      # The regex is @thought_done_re ~r/^✻\s+\w+.*for\s+\d/
      # "✻ Thought for 3s" should match
      assert {:working, "explain this code"} = ActivityParser.parse(content)
    end

    test "running tool returns {:tool, _, _} via find_tool_above" do
      content =
        with_status_bar([
          "❯\u00A0run the tests",
          "",
          "⏺ Bash(mix test)",
          "",
          "  Running mix test",
          ""
        ])

      assert {:tool, "Bash", _} = ActivityParser.parse(content)
    end
  end

  describe "to_display_string/1" do
    test "waiting state" do
      assert "Allow Bash?" = ActivityParser.to_display_string({:waiting, "Allow Bash?"})
    end

    test "tool state" do
      assert "Reading server.ex" = ActivityParser.to_display_string({:tool, "Read", "server.ex"})
    end

    test "working state" do
      assert "fix the bug" = ActivityParser.to_display_string({:working, "fix the bug"})
    end

    test "idle with prompt" do
      assert "fix the bug" = ActivityParser.to_display_string({:idle, "fix the bug"})
    end

    test "idle without prompt" do
      assert nil == ActivityParser.to_display_string({:idle, nil})
    end

    test "nil" do
      assert nil == ActivityParser.to_display_string(nil)
    end
  end
end
