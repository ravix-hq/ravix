defmodule Ravix.Fountain.Shapes do
  @moduledoc """
  The shapes Fountain actually sends, and the ones the rest of Ravix reads.

  The same boundary `Ravix.GitHub.Shapes` is for GitHub, and for the same
  reason: Fountain's JSON arrives as string-keyed maps, and a field addressed
  by a string nobody checks answers `nil` when it is misspelled or renamed.
  `Ravix.Tracks.Transcript.Event` closed that door for the event stream; this
  closes it for the conversations and sandboxes, which is where the rest of
  Ravix asks its questions.

  Past these functions a conversation is a `Conversation` and a sandbox is a
  `Sandbox`, with atom keys and `@enforce_keys`, so a misspelled field is a
  compile error rather than a `nil` that reads as "not live".

  ## The status vocabulary

  A conversation's status was the clearest argument for doing this. It was
  spelled as raw strings in five modules with four different subsets of the
  vocabulary: `~w(pending idle running)` twice, as a literal, in
  `Ravix.MachineCache` and `Ravix.Projects.Machine`; `"running"` and
  `"failed"` in `Ravix.Tracks`; `["running", "pending"]` and
  `["failed", "terminated"]` in `Ravix.PromptQueue.Server`. Whether `idle`
  belonged in the fourth of those could only be answered by reading what the
  clause below it fell through to.

  It lives here once now, as `live?/1`, `busy?/1` and `ended?/1`, which are
  the three questions Ravix actually asks. The words themselves are Fountain's
  and the mapping is a fixed table with an `:other` fallback, never
  `String.to_atom/1`: a provider that invents a status must not be able to
  grow the atom table. `:other` is not live, not busy and not ended, which is
  what each of those call sites already did with a word it did not know.

  ## Times

  `inserted_at` stays the ISO 8601 string Fountain sent. Ravix only ever sorts
  by it -- `newest/1` is the whole of its use -- and ISO 8601 sorts
  lexicographically, so parsing it would buy nothing and lose the ordering of
  a value that failed to parse. `last_active_at` is parsed, because every
  caller wants a `DateTime` to compare against a read receipt.

  `turn_count` keeps `nil` apart from `0`. A conversation Fountain did not
  count is not one that ran no turns, and `Ravix.PromptQueue.Server` writes a
  different message for each.
  """

  defmodule Conversation do
    @moduledoc """
    A conversation, as `GET /api/conversations` lists it or `/:id` serves it.

    The list carries `sandbox_id` but serves `"sandbox": null`, so on a listed
    conversation `sprite_name` is nil and stays nil. Only the detail endpoint
    embeds the sandbox. This is why `Ravix.MachineCache.sprite_for/3` is a
    second call rather than a field off the list.
    """

    @enforce_keys [
      :id,
      :status,
      :sandbox_id,
      :sprite_name,
      :inserted_at,
      :last_active_at,
      :turn_count
    ]
    defstruct @enforce_keys

    @typedoc """
    Fountain's own words for where a conversation is, plus `:other` for one
    this version of Ravix does not know.
    """
    @type status :: :pending | :idle | :running | :failed | :terminated | :other

    @type t :: %__MODULE__{
            id: String.t() | nil,
            status: status(),
            sandbox_id: String.t() | nil,
            sprite_name: String.t() | nil,
            inserted_at: String.t() | nil,
            last_active_at: DateTime.t() | nil,
            turn_count: integer() | nil
          }
  end

  defmodule Sandbox do
    @moduledoc "A sandbox, as `GET /api/sandboxes/:id` serves it."

    @enforce_keys [:id, :sprite_name]
    defstruct @enforce_keys

    @type t :: %__MODULE__{id: String.t() | nil, sprite_name: String.t() | nil}
  end

  @statuses %{
    "pending" => :pending,
    "idle" => :idle,
    "running" => :running,
    "failed" => :failed,
    "terminated" => :terminated
  }

  # A conversation that has not ended and may still be attached to.
  @live [:pending, :idle, :running]

  # A conversation mid-turn, which cannot be sent another prompt yet.
  @busy [:pending, :running]

  # A conversation that will never run again.
  @ended [:failed, :terminated]

  @doc "One conversation, from the JSON Fountain sent."
  @spec conversation(map()) :: Conversation.t()
  def conversation(raw) when is_map(raw) do
    %Conversation{
      id: raw["id"],
      status: Map.get(@statuses, raw["status"], :other),
      sandbox_id: raw["sandbox_id"],
      sprite_name: get_in(raw, ["sandbox", "sprite_name"]),
      inserted_at: raw["inserted_at"],
      last_active_at: time(raw["last_active_at"]),
      turn_count: raw["turn_count"]
    }
  end

  @doc "A list of conversations, from the JSON Fountain sent."
  @spec conversations([map()]) :: [Conversation.t()]
  def conversations(raw) when is_list(raw), do: Enum.map(raw, &conversation/1)

  @doc "One sandbox, from the JSON Fountain sent."
  @spec sandbox(map()) :: Sandbox.t()
  def sandbox(raw) when is_map(raw),
    do: %Sandbox{id: raw["id"], sprite_name: raw["sprite_name"]}

  @doc """
  The conversation is attached to a machine that may still be woken.

  `pending`, `idle` or `running`. This is the question
  `Ravix.MachineCache.machine_of/3` asks of the list to decide which sandbox
  a project is on, and the one `Ravix.Projects.Machine` asks to decide
  whether to terminate a conversation before retiring its agent.
  """
  @spec live?(Conversation.t()) :: boolean()
  def live?(%Conversation{status: status}), do: status in @live

  @doc """
  The conversation is taking a turn and will refuse another prompt.

  `pending` or `running`. An `idle` conversation is deliberately not busy:
  idle is exactly the state a queued prompt is waiting for.
  """
  @spec busy?(Conversation.t()) :: boolean()
  def busy?(%Conversation{status: status}), do: status in @busy

  @doc "The conversation ended and will not run again: `failed` or `terminated`."
  @spec ended?(Conversation.t()) :: boolean()
  def ended?(%Conversation{status: status}), do: status in @ended

  @doc """
  The most recently created conversation, by `inserted_at`, or `nil` for none.

  Both callers that derive a project's machine from its conversation list
  wanted this and wrote it separately. One that Fountain gave no
  `inserted_at` sorts last rather than crashing the comparison.
  """
  @spec newest([Conversation.t()]) :: Conversation.t() | nil
  def newest(conversations) do
    conversations
    |> Enum.sort_by(&(&1.inserted_at || ""), :desc)
    |> List.first()
  end

  # Fountain's timestamps are ISO 8601. One that is not is no timestamp:
  # every caller compares it, and a wrong comparison is worse than none.
  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  defp time(_other), do: nil
end
