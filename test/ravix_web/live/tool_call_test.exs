defmodule RavixWeb.Live.ToolCallTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Ravix.Tracks.Transcript
  alias Ravix.Tracks.Transcript.Block
  alias Ravix.Tracks.Transcript.Detail
  alias RavixWeb.Live.ToolCall

  # A call as `Ravix.Tracks.Transcript` builds one from its ACP frames, so
  # the kind, arguments, locations and diffs are the parser's, not a guess
  # at its output.
  defp call(title, update, result \\ nil) do
    update = Map.new(update, fn {key, value} -> {to_string(key), stringify(value)} end)

    tool =
      Block.tool(
        %{id: "id", name: title, summary: nil},
        nil,
        Transcript.detail(Detail.new(), update)
      )

    case result do
      nil -> tool
      output -> %{tool | status: :done, output: output}
    end
  end

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp draw(tool, workdir \\ nil),
    do: render_component(&ToolCall.tool_call/1, block: tool, workdir: workdir)

  describe "label/1 and icon_name/1" do
    for {kind, title, input, label, icon} <- [
          {"execute", "`ls`", %{command: "ls"}, "Bash", "terminal"},
          {"read", "Read a.ex", %{file_path: "a.ex"}, "Read", "file"},
          {"edit", "Edit a.ex", %{file_path: "a.ex", old_string: "a", new_string: "b"}, "Edit",
           "pencil"},
          {"edit", "Write a.ex", %{file_path: "a.ex", content: "a"}, "Write", "document"},
          {"search", "grep", %{pattern: "TODO"}, "Search", "search"},
          {"fetch", "Fetch", %{url: "https://example.test"}, "Fetch", "globe"},
          {"delete", "Delete a.ex", %{path: "a.ex"}, "Delete", "x"},
          {"move", "Move a.ex", %{source: "a.ex"}, "Move", "folder"},
          {"think", "Think", %{}, "Think", "sparkle"},
          {"other", "Terminal", %{cmd: ["bash", "-lc", "ls"]}, "Bash", "terminal"},
          {"other", "TodoWrite", %{todos: []}, "TodoWrite", "wrench"},
          {"other", "mcp__github__create_issue", %{title: "x"}, "create_issue", "wrench"},
          {"other", "Ask the user a question", %{question: "?"}, "Tool", "wrench"},
          {nil, nil, %{}, "Tool", "wrench"}
        ] do
      @tag case: {kind, title, input, label, icon}
      test "#{kind || "no kind"} #{inspect(title)} is #{label}", %{
        case: {kind, title, input, label, icon}
      } do
        tool = call(title, %{kind: kind, rawInput: input})
        assert ToolCall.label(tool) == label
        assert ToolCall.icon_name(tool) == icon
      end
    end
  end

  describe "target/1" do
    test "a shell call is its command, whichever way the adapter sent it" do
      assert ToolCall.target(call("`ls`", %{kind: "execute", rawInput: %{command: "ls -la"}})) ==
               "ls -la"

      assert ToolCall.target(call("x", %{kind: "execute", rawInput: %{cmd: ["git", "status"]}})) ==
               "git status"

      assert ToolCall.target(
               call("x", %{kind: "execute", rawInput: %{cmd: ["sh", "-c", "a\nb"]}})
             ) ==
               "a\nb"

      # Only the title is left: its backticks are the adapter's, not the command's.
      assert ToolCall.target(call("`mix test`", %{kind: "execute"})) == "mix test"
    end

    test "a file call is its location before its arguments" do
      tool =
        call("Read", %{
          kind: "read",
          rawInput: %{file_path: "relative.ex"},
          locations: [%{path: "/w/lib/a.ex"}]
        })

      assert ToolCall.target(tool) == "/w/lib/a.ex"
    end

    test "a title that is only the tool's name is not repeated as its target" do
      assert ToolCall.target(call("TodoWrite", %{kind: "other", rawInput: %{todos: []}})) == nil
      assert ToolCall.target(call("   ", %{kind: "other"})) == nil
    end
  end

  test "first_line/2 cuts to one line, named from the track's directory" do
    assert ToolCall.first_line(nil, "/w") == {nil, 0}
    assert ToolCall.first_line("/w/lib/a.ex", "/w/") == {"lib/a.ex", 0}
    assert ToolCall.first_line("/elsewhere/a.ex", "/w") == {"/elsewhere/a.ex", 0}

    assert ToolCall.first_line("python3 - <<'PY'\r\nprint(1)\nPY\n", nil) ==
             {"python3 - <<'PY'", 2}
  end

  describe "tool_call/1" do
    test "the row is one line: icon, name, first line of the target" do
      tool =
        call("`python3 - <<'PY'`", %{
          kind: "execute",
          rawInput: %{command: "python3 - <<'PY'\nprint(1)\nPY"}
        })

      html = draw(tool)
      summary = html |> LazyHTML.from_fragment() |> LazyHTML.query("summary")

      assert LazyHTML.attribute(summary, "title") == ["python3 - <<'PY'"]
      assert LazyHTML.attribute(summary, "aria-label") == ["Bash, running: python3 - <<'PY'"]
      assert summary |> LazyHTML.query(".tool-name") |> LazyHTML.text() == "Bash"
      assert summary |> LazyHTML.query(".tool-target") |> LazyHTML.text() == "python3 - <<'PY'"
      assert summary |> LazyHTML.query(".tool-more") |> LazyHTML.text() =~ "+2 lines"
      assert summary |> LazyHTML.query("svg.tool-icon") |> Enum.count() == 1
      refute LazyHTML.text(summary) =~ "print(1)"
    end

    test "a shell call's body is its command with real newlines, then the output" do
      tool =
        call(
          "`cat <<EOF`",
          %{kind: "execute", rawInput: %{command: "cat <<EOF\none\nEOF", description: "Say one"}},
          "one"
        )

      doc = tool |> draw() |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("pre.tool-command") |> LazyHTML.text() == "cat <<EOF\none\nEOF"
      assert doc |> LazyHTML.query("pre.tool-output") |> LazyHTML.text() == "one"
      assert doc |> LazyHTML.query(".tool-note") |> LazyHTML.text() =~ "Say one"
      # Not JSON: the command's newlines are not escaped into a string.
      refute LazyHTML.to_html(doc) =~ "\\n"
      refute LazyHTML.to_html(doc) =~ "&quot;command&quot;"
      # Done calls carry no status chip or status in their name.
      assert doc |> LazyHTML.query("summary") |> LazyHTML.attribute("aria-label") == [
               "Bash: cat <<EOF"
             ]

      assert doc |> LazyHTML.query(".chip") |> Enum.count() == 0
    end

    test "an edit shows its path and diff; a write its content; leftover arguments are listed" do
      edit =
        call("Edit /w/a.ex", %{
          kind: "edit",
          rawInput: %{
            file_path: "/w/a.ex",
            old_string: "old",
            new_string: "new",
            replace_all: true
          },
          content: [%{type: "diff", path: "/w/a.ex", oldText: "old\n", newText: "new\n"}]
        })

      doc = edit |> draw("/w") |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query(".tool-target") |> LazyHTML.text() == "a.ex"
      assert doc |> LazyHTML.query(".diff-del") |> LazyHTML.text() =~ "old"
      assert doc |> LazyHTML.query(".diff-add") |> LazyHTML.text() =~ "new"
      assert doc |> LazyHTML.query(".tool-args dt") |> LazyHTML.text() == "replace_all"
      assert doc |> LazyHTML.query(".tool-args dd") |> LazyHTML.text() == "true"

      write =
        call("Write /w/b.ex", %{
          kind: "edit",
          rawInput: %{file_path: "/w/b.ex", content: "line 1\nline 2"}
        })

      doc = write |> draw("/w") |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query(".tool-name") |> LazyHTML.text() == "Write"
      assert doc |> LazyHTML.query("pre.tool-content") |> LazyHTML.text() == "line 1\nline 2"
      assert doc |> LazyHTML.query(".tool-args") |> Enum.count() == 0
    end

    test "a read with a descriptive title keeps the title as a note" do
      doc =
        "Read code"
        |> call(%{kind: "read", rawInput: %{file_path: "app.ex", limit: 20}}, "contents")
        |> draw()
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query(".tool-note") |> LazyHTML.text() == "Read code"
      assert doc |> LazyHTML.query(".tool-body > p > code") |> LazyHTML.text() == "app.ex"
      assert doc |> LazyHTML.query(".tool-args dd") |> LazyHTML.text() == "20"
    end

    test "only a tool with no better shape shows its arguments as JSON" do
      doc =
        "mcp__tracker__create"
        |> call(%{kind: "other", rawInput: %{title: "Bug", labels: ["a", "b"]}})
        |> draw()
        |> LazyHTML.from_fragment()

      json = doc |> LazyHTML.query(".tool-body > pre") |> LazyHTML.text()
      assert Jason.decode!(json) == %{"title" => "Bug", "labels" => ["a", "b"]}
      assert doc |> LazyHTML.query(".tool-args") |> Enum.count() == 0
    end

    test "hostile input is text everywhere it is drawn" do
      hostile = "<script>alert(1)</script>" <> String.duplicate("A", 5_000)

      html =
        "<img src=x onerror=alert(1)>"
        |> call(%{kind: "execute", rawInput: %{command: hostile, cwd: "<b>dir</b>"}}, hostile)
        |> draw()

      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("script, img, b") |> Enum.count() == 0
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert doc |> LazyHTML.query("summary") |> LazyHTML.attribute("title") == [hostile]

      assert doc |> LazyHTML.query(".tool-note") |> LazyHTML.text() =~
               "<img src=x onerror=alert(1)>"

      assert doc |> LazyHTML.query(".tool-args dd") |> LazyHTML.text() == "<b>dir</b>"
    end
  end
end
