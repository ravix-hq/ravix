defmodule Ravix.Tracks.Transcript.Block do
  @moduledoc """
  One drawn thing in a turn: the five shapes `src/components/Transcript.tsx`
  rendered, one struct each, and the agent's plan, which it never did.

  These were a `@type block :: map()` -- which is to say `any` -- carrying a
  `:kind` field to say which of the five a given map was. That is a
  TypeScript discriminated union transliterated, and it cost exactly what an
  untyped map costs here: `visible_block?/1` had to match on `%{kind: :tool}`
  rather than on a shape, a block built without `ended_at` reached the
  template as a `nil` nobody declared, and Dialyzer had nothing to check.

  In Elixir the struct name *is* the tag, so there is no `:kind` field. A
  block is matched by what it is:

      def visible_block?(%Block.Tool{}), do: true

  and the template dispatches with a function head per struct rather than
  five `:if` comparisons against the same field.

  Timestamps are the event log's own ISO-8601 strings throughout: when the
  chunk landed, not when the model produced it.
  """

  alias Ravix.Tracks.Transcript.Detail

  defmodule Text do
    @moduledoc "The reply, as markdown. Adjacent chunks are folded into one block."

    @enforce_keys [:body, :started_at, :ended_at]
    defstruct [:body, :started_at, :ended_at]

    @type t :: %__MODULE__{
            body: String.t(),
            started_at: String.t() | nil,
            ended_at: String.t() | nil
          }
  end

  defmodule Thinking do
    @moduledoc "Reasoning, folded away by the template once the turn is over."

    @enforce_keys [:body, :started_at, :ended_at]
    defstruct [:body, :started_at, :ended_at]

    @type t :: %__MODULE__{
            body: String.t(),
            started_at: String.t() | nil,
            ended_at: String.t() | nil
          }
  end

  defmodule Tool do
    @moduledoc """
    One tool call and its result, paired on the ACP `toolCallId`.

    `status` is `:running` until a terminal update lands, then `:done` or
    `:error`. `detail` is the second read of both frames; see
    `Ravix.Tracks.Transcript.Detail`.
    """

    alias Ravix.Tracks.Transcript.Detail

    @enforce_keys [:id, :name, :summary, :status, :output, :started_at, :ended_at, :detail]
    defstruct [:id, :name, :summary, :status, :output, :started_at, :ended_at, :detail]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            name: String.t() | nil,
            summary: String.t() | nil,
            status: :running | :done | :error,
            output: String.t(),
            started_at: String.t() | nil,
            ended_at: String.t() | nil,
            detail: Detail.t()
          }
  end

  defmodule Raw do
    @moduledoc "A line the adapter emitted that is not ACP, shown as it arrived."

    @enforce_keys [:body]
    defstruct [:body]

    @type t :: %__MODULE__{body: String.t()}
  end

  defmodule Failure do
    @moduledoc """
    A stage Fountain failed, and whatever it said about it.

    Drawn even when the reason is `""`: that a stage failed at all is the
    news, and a silent turn is what #35 was.
    """

    @enforce_keys [:stage, :body]
    defstruct [:stage, :body]

    @type t :: %__MODULE__{stage: String.t() | nil, body: String.t()}
  end

  defmodule Plan do
    @moduledoc """
    The agent's checklist, as it last stood in this turn.

    Every plan the agent reports is the whole list rather than a change to
    it (`Managoat.ACP.Blocks`: an ACP `plan` update, or a `TodoWrite` /
    `update_plan` call the library reconstructs one from), so a turn keeps
    only the newest and draws it where that one arrived. A cleared list
    removes the block rather than drawing an empty one.

    `status` is closed over the three ACP names, with anything else read as
    `:pending`: an entry the agent has not said it finished is not finished.
    """

    defmodule Entry do
      @moduledoc "One line of a plan."

      @enforce_keys [:content, :status]
      defstruct [:content, :status]

      @type t :: %__MODULE__{content: String.t(), status: :pending | :in_progress | :completed}
    end

    @enforce_keys [:entries]
    defstruct [:entries]

    @type t :: %__MODULE__{entries: [Entry.t()]}

    @statuses %{"pending" => :pending, "in_progress" => :in_progress, "completed" => :completed}

    @doc """
    A plan from the library's entries, or nil when none of them has any text.

    Entries are ACP's, string-keyed: `content`, `status`, and an optional
    `priority` this does not draw. An entry without a string `content` is
    dropped rather than drawn as a blank line.
    """
    @spec from_entries(term()) :: t() | nil
    def from_entries(entries) when is_list(entries) do
      case for(
             %{"content" => content} = entry <- entries,
             is_binary(content) and String.trim(content) != "",
             do: %Entry{content: content, status: Map.get(@statuses, entry["status"], :pending)}
           ) do
        [] -> nil
        kept -> %__MODULE__{entries: kept}
      end
    end

    def from_entries(_entries), do: nil
  end

  @typedoc "Any of the six. Matched by struct, never by a tag field."
  @type t :: Text.t() | Thinking.t() | Tool.t() | Raw.t() | Failure.t() | Plan.t()

  @doc "A tool call as it starts, before any result has been paired onto it."
  @spec tool(map(), String.t() | nil, Detail.t()) :: Tool.t()
  def tool(block, ts, detail) do
    %Tool{
      id: block.id,
      name: block.name,
      summary: block.summary,
      status: :running,
      output: "",
      started_at: ts,
      ended_at: nil,
      detail: detail
    }
  end
end
