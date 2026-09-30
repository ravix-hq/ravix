defmodule RavixWeb.Live.ToolCall do
  @moduledoc """
  One tool call inside a turn's folded work, drawn as a single line.

  The line is an icon, the tool's name and the one thing it was run on --- the
  command, the path, the pattern --- in monospace and cut to one line, so a
  turn of eighty calls scans as a list rather than a wall of wrapped shell.
  Opening it shows what that thing really was: a command with its own
  newlines, the file and its diff, and JSON only for a tool whose arguments
  have no better shape.

  The name comes from the ACP `kind` first, since that is the adapter's own
  classification, then from the arguments, then from the title when it looks
  like a tool's name rather than a sentence. A call none of those place is a
  "Tool" with a wrench, never a blank.

  Everything here is agent output and is drawn through HEEx's escaping; none
  of it reaches `RavixWeb.Markdown`.
  """
  use RavixWeb, :html

  alias Ravix.Tracks.Transcript.Block.Tool

  @kinds %{
    execute: {"Bash", "terminal"},
    read: {"Read", "file"},
    edit: {"Edit", "pencil"},
    delete: {"Delete", "x"},
    move: {"Move", "folder"},
    search: {"Search", "search"},
    fetch: {"Fetch", "globe"},
    think: {"Think", "sparkle"}
  }

  # The argument each kind is about, in the order they are looked for, and
  # the ones its body already draws in its own shape. What is left over is
  # listed as it is, so no argument is hidden.
  @primary %{
    execute: ~w(command cmd),
    read: ~w(file_path path notebook_path),
    edit: ~w(file_path path notebook_path),
    delete: ~w(file_path path),
    move: ~w(file_path path source),
    search: ~w(pattern query),
    fetch: ~w(url query),
    think: ~w(thought),
    other: ~w(command cmd file_path path pattern query url)
  }

  @drawn %{edit: ~w(old_string new_string content edits)}

  # A title such as `TodoWrite` or `mcp__github__create_issue` is the tool's
  # own name; one with spaces in it is a description of the call.
  @identifier ~r/\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/

  @doc """
  The tool's name for the row: "Bash", "Read", "Edit", "Write", "Search",
  "Fetch" and so on, or "Tool" when nothing says what it was.
  """
  @spec label(Tool.t()) :: String.t()
  def label(%Tool{} = tool), do: tool |> identify() |> elem(0)

  @doc "The `RavixWeb.Icons` name drawn beside `label/1`."
  @spec icon_name(Tool.t()) :: String.t()
  def icon_name(%Tool{} = tool), do: tool |> identify() |> elem(1)

  # The kinds a turn's folded line shows, as an icon and the word read out in
  # its place. Edit and Write share a pencil there: at that size the line
  # says what sort of work happened, not which call did it. Anything else,
  # a wrench included, would be noise on a line meant to be glanced at.
  @summary_kinds %{
    execute: {"terminal", "shell"},
    read: {"file", "read"},
    edit: {"pencil", "edit"},
    search: {"search", "search"},
    fetch: {"globe", "web"}
  }

  @doc """
  The call's kind as a turn's folded line shows it, `{icon, word}`, or nil
  for a kind that line leaves out. Classified as the row itself is.
  """
  @spec summary_kind(Tool.t()) :: {String.t(), String.t()} | nil
  def summary_kind(%Tool{} = tool), do: Map.get(@summary_kinds, shape(tool))

  defp identify(%Tool{name: name} = tool) do
    case shape(tool) do
      :edit ->
        if write?(tool), do: {"Write", "document"}, else: @kinds.edit

      :other ->
        if is_binary(name) and name =~ @identifier,
          do: {tool_name(name), "wrench"},
          else: {"Tool", "wrench"}

      kind ->
        Map.fetch!(@kinds, kind)
    end
  end

  # The kind the call is drawn as. An adapter that sends no kind, or `other`,
  # for what is plainly a shell command still gets a shell call's row.
  defp shape(%Tool{detail: %{kind: kind, input: input}}) do
    cond do
      Map.has_key?(@kinds, kind) -> kind
      command(input) -> :execute
      true -> :other
    end
  end

  # An MCP tool is `mcp__<server>__<tool>`; the tool is the part a person
  # would call it by.
  defp tool_name("mcp__" <> _ = name), do: name |> String.split("__") |> List.last()
  defp tool_name(name), do: name

  # A write is an edit with a whole file for its argument rather than a
  # change to one, which is how the Claude adapter reports its Write tool.
  defp write?(%Tool{name: name, detail: %{input: input}}) do
    (is_binary(name) and name =~ ~r/\AWrite\b/) or
      (is_binary(input["content"]) and not Map.has_key?(input, "old_string"))
  end

  @doc """
  The one thing the call was run on, whole: the command (every line of it),
  the path, the pattern or the URL. Nil when there is nothing better than the
  name the row already shows.
  """
  @spec target(Tool.t()) :: String.t() | nil
  def target(%Tool{detail: detail, name: name} = tool) do
    primary(shape(tool), detail) || from_name(name, label(tool))
  end

  defp primary(:execute, %{input: input}), do: command(input)

  defp primary(kind, %{input: input, paths: paths}) do
    path_kind? = kind in [:read, :edit, :delete, :move]

    (path_kind? && List.first(paths)) ||
      Enum.find_value(Map.fetch!(@primary, kind), fn key -> present(input[key]) end)
  end

  # A shell call's command: a string, or an argv, which Codex sends as
  # `["bash", "-lc", script]` and which reads as the script.
  defp command(input) do
    case input["command"] || input["cmd"] do
      value when is_binary(value) ->
        present(value)

      [shell, flag, script] when shell in ~w(bash sh zsh) and flag in ~w(-c -lc) ->
        present(script)

      [_ | _] = argv ->
        if Enum.all?(argv, &is_binary/1), do: present(Enum.join(argv, " "))

      _ ->
        nil
    end
  end

  # The Claude adapter titles a shell call with its command in backticks and
  # a read with "Read <path>"; either is still better than an empty row. The
  # titles it gives a call before its input has streamed in say nothing
  # about it, and are never shown as though they did (RAV-92).
  @placeholders ["Preparing file…", "Terminal"]

  defp from_name(name, label) when is_binary(name) do
    trimmed = name |> String.trim() |> String.trim("`")
    if trimmed not in ["", label | @placeholders], do: trimmed
  end

  defp from_name(_name, _label), do: nil

  defp present(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp present(_value), do: nil

  @doc """
  The row's text for `target/1`: its first line, named relative to the
  track's directory, and how many lines were left off.
  """
  @spec first_line(String.t() | nil, String.t() | nil) :: {String.t() | nil, non_neg_integer()}
  def first_line(nil, _workdir), do: {nil, 0}

  def first_line(target, workdir) do
    [first | rest] = target |> String.trim() |> String.split(["\r\n", "\n"])
    {relative(first, workdir), length(rest)}
  end

  @doc """
  `text` with the track's directory taken out wherever it names it: a path
  under it becomes relative, the directory itself becomes `.`, and a
  leading `cd <dir> &&`, which is where the agent already is, goes. The
  sandbox's absolute paths are the machine's business, not the reader's.

  The row applies it to everything it draws that the machine wrote about
  itself: the line, the command, the note, the arguments and the output
  (RAV-92's "File created successfully at: /home/sprite/work/..."). A
  file's content and its diff lines are the file's own words, and stay as
  they are.
  """
  @spec relative(String.t(), String.t() | nil) :: String.t()
  def relative(text, workdir) when is_binary(workdir) do
    case String.trim_trailing(workdir, "/") do
      "" ->
        text

      root ->
        dir = Regex.escape(root)

        text
        |> String.replace(~r/\Acd\s+(['"]?)#{dir}\/?\1\s*(?:&&|;)\s*/, "")
        |> String.replace(~r/(?<![\w.\/-])#{dir}\/(?=[^\s\/])/, "")
        |> String.replace(~r/(?<![\w.\/-])#{dir}\/?(?![\w.\/-])/, ".")
    end
  end

  def relative(text, _workdir), do: text

  @doc """
  The arguments the body does not already draw in its own shape, sorted by
  name. A tool with no known kind keeps all of them, as JSON.
  """
  @spec rest(Tool.t()) :: [{String.t(), term()}]
  def rest(%Tool{detail: %{input: input}} = tool) do
    kind = shape(tool)
    drawn = ["description" | Map.fetch!(@primary, kind) ++ Map.get(@drawn, kind, [])]

    input
    |> Map.drop(drawn)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  A sentence about the call, when the adapter gave one: a shell call's
  `description`, or a title that says more than the command or path does.
  The Claude adapter titles a call with its own command or "Read <path>",
  which the row already shows, so those are left out.
  """
  @spec note(Tool.t(), String.t() | nil) :: String.t() | nil
  def note(%Tool{name: name, detail: %{input: input}} = tool, workdir \\ nil) do
    # A title is only ever the target when nothing else was, so a title
    # implies a target to compare it with. The adapter names a path in a
    # title relative to its own directory, so both forms are compared.
    title = from_name(name, label(tool))
    target = target(tool)

    present(input["description"]) ||
      if(
        title && !String.contains?(title, target) &&
          !String.contains?(title, relative(target, workdir)),
        do: title
      )
  end

  # What a screen reader announces for the row, which otherwise would be
  # the summary's text run together with the status chip.
  defp accessible_name(label, :done, nil), do: label
  defp accessible_name(label, :done, line), do: "#{label}: #{line}"
  defp accessible_name(label, status, nil), do: "#{label}, #{status}"
  defp accessible_name(label, status, line), do: "#{label}, #{status}: #{line}"

  attr :id, :string, default: nil
  attr :block, Tool, required: true
  attr :workdir, :string, default: nil

  @doc "The call's row and, opened, its body."
  def tool_call(assigns) do
    %{block: tool, workdir: workdir} = assigns
    target = target(tool)
    {line, more} = first_line(target, workdir)
    {label, icon} = identify(tool)
    shape = shape(tool)

    assigns =
      assign(assigns,
        label: label,
        icon: icon,
        target: target,
        line: line,
        more: more,
        shell?: shape == :execute,
        write?: label == "Write",
        structured?: shape == :other,
        rest: if(shape == :other, do: [], else: rest(tool)),
        note: note(tool, workdir),
        named: accessible_name(label, tool.status, line)
      )

    ~H"""
    <details id={@id} class="workspace-tool" phx-mounted={JS.ignore_attributes("open")}>
      <summary aria-label={@named} title={@line}>
        <.icon name={@icon} size={13} class="tool-icon" />
        <span class="tool-name">{@label}</span>
        <code :if={@line} class="tool-target">{@line}</code>
        <span :if={@more > 0} class="tool-more">+{@more} {if @more == 1, do: "line", else: "lines"}</span>
        <span :if={@block.status != :done} class={"chip tool-#{@block.status}"}>{@block.status}</span>
      </summary>
      <div class="tool-body">
        <p :if={@note} class="tool-note">{relative(@note, @workdir)}</p>
        <pre :if={@shell? && @target} class="tool-command">{relative(@target, @workdir)}</pre>
        <p :if={!@shell? && !@structured? && @target && @block.detail.paths == []}>
          <code>{relative(@target, @workdir)}</code>
        </p>
        <p :for={path <- @block.detail.paths}><code>{relative(path, @workdir)}</code></p>
        <dl :if={@rest != []} class="tool-args">
          <%= for {key, value} <- @rest do %>
            <dt>{key}</dt>
            <dd>{relative(if(is_binary(value), do: value, else: Jason.encode!(value)), @workdir)}</dd>
          <% end %>
        </dl>
        <pre :if={@structured? && @block.detail.input != %{}}>{Jason.encode!(@block.detail.input, pretty: true)}</pre>
        <div :for={edit <- @block.detail.edits}>
          <strong>{relative(edit.path, @workdir)}</strong><pre><span :for={line <- edit.lines} class={"diff-#{line.kind}"}>{line.text}{"\n"}</span></pre>
        </div>
        <pre
          :if={@write? && @block.detail.edits == [] && is_binary(@block.detail.input["content"])}
          class="tool-content"
        >{@block.detail.input["content"]}</pre>
        <pre :if={@block.output != ""} class="tool-output">{relative(@block.output, @workdir)}</pre>
      </div>
    </details>
    """
  end
end
