defmodule Ravix.Fountain.Shapes do
  @moduledoc """
  The shapes Fountain actually sends, and the ones the rest of Ravix reads.

  The same boundary `Ravix.GitHub.Shapes` is for GitHub, and for the same
  reason: Fountain's JSON arrives as string-keyed maps, and a field addressed
  by a string nobody checks answers `nil` when it is misspelled or renamed.
  `Ravix.Tracks.Transcript.Event` closed that door for the event stream; this
  closes it for the conversations, sandboxes and the catalog, which is where
  the rest of Ravix asks its questions.

  Past these functions a conversation is a `Conversation`, a sandbox is a
  `Sandbox` and the catalog is a `Catalog`, with atom keys and
  `@enforce_keys`, so a misspelled field is a compile error rather than a
  `nil` that reads as "not live".

  ## The catalog, and what a missing shape costs

  `Catalog` arrived last and is worth recording, because the code that read
  the catalog without one shows what this module is for. `GET /api/catalog`
  was the one endpoint here whose answer Ravix *branches* on and had no
  shape, so `Ravix.Projects.Machine` reached into the raw record through a
  private `field/2` that tried both spellings of every key:

      defp field(map, key) when is_map(map) and is_atom(key),
        do: map[key] || map[Atom.to_string(key)]

      defp field(map, key) when is_map(map) and is_binary(key),
        do: map[key] || Enum.find_value(map, &atom_keyed(&1, key))

  Fountain sends JSON, so the atom halves of both clauses could never match
  in production; the second clause's scan over the map existed so that a
  *test* could write `%{models: %{codex: [...]}}` and be understood. That is
  the wrong way round. A stub should answer the shape the provider answers,
  and a lookup that reads either spelling cannot tell a key it does not
  recognise from one that is not there --- which matters here, because
  `Ravix.Projects.Machine.pick_runtime/1` treats "no models for this runtime"
  as a reason to fall through to a default rather than as something to report.

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

    `model` is the conversation's own model (Fountain ADR 0061), and nil
    when it follows its agent's. A Fountain that predates the field sends
    none, which reads the same as following the agent, and that is what
    such a Fountain does.
    """

    @enforce_keys [
      :id,
      :status,
      :sandbox_id,
      :sprite_name,
      :inserted_at,
      :last_active_at,
      :turn_count,
      :model
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
            turn_count: integer() | nil,
            model: String.t() | nil
          }
  end

  defmodule Turn do
    @moduledoc """
    One prompt and what became of it, as `GET /api/conversations/:id/turns`
    lists it.

    Turns live apart from the output: the events carry what the machine said,
    and this carries what it was asked and whether the asking finished.
    `status` and `origin` stay strings -- Fountain's own vocabularies, which
    Ravix reports rather than branches on. `client_request_id` is the name the
    sender gave the prompt that opened the turn, if it gave one; the prompt
    queue sends its row id there.
    """

    @enforce_keys [:id, :prompt, :origin, :status, :inserted_at, :client_request_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            prompt: String.t() | nil,
            origin: String.t() | nil,
            status: String.t() | nil,
            inserted_at: String.t() | nil,
            client_request_id: String.t() | nil
          }
  end

  defmodule Sandbox do
    @moduledoc "A sandbox, as `GET /api/sandboxes/:id` serves it."

    @enforce_keys [:id, :sprite_name]
    defstruct @enforce_keys

    @type t :: %__MODULE__{id: String.t() | nil, sprite_name: String.t() | nil}
  end

  defmodule Catalog do
    @moduledoc """
    What this Fountain can build an agent with, as `GET /api/catalog` serves it.

    Two of the four keys it serves. `package_managers` and `mcp_servers` are
    not here because nothing in Ravix reads them: an environment's `packages`
    is whatever the project's settings panel was given, and a shape that
    carried fields no caller asks for would make the next reader wonder which
    of them a decision depends on.

    `runtimes` is Fountain's vocabulary and stays strings --- Ravix compares
    them to one default and otherwise passes them through --- so `models` is
    keyed by a string too, for the same reason a Sprites service's `env` is.
    `models_for/2` is the only way the pairing is read, which is what stops a
    caller reaching into the map with whichever spelling it has to hand.
    """

    @enforce_keys [:runtimes, :models]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            runtimes: [String.t()],
            models: %{String.t() => [String.t()]}
          }

    @doc """
    A catalog that says nothing, which is what a Fountain that could not be
    read amounts to.

    A real value rather than a `nil` every caller then has to test: the
    decision `Ravix.Projects.Machine.pick_runtime/1` makes from an empty
    catalog is the same one it makes from no catalog at all.
    """
    @spec empty() :: t()
    def empty, do: %__MODULE__{runtimes: [], models: %{}}

    @doc "The models this catalog offers for `runtime`, or `[]` for a runtime it does not list."
    @spec models_for(t(), String.t()) :: [String.t()]
    def models_for(%__MODULE__{models: models}, runtime), do: Map.get(models, runtime, [])
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
      turn_count: raw["turn_count"],
      model: string_or_nil(raw["model"])
    }
  end

  @doc "A list of conversations, from the JSON Fountain sent."
  @spec conversations([map()]) :: [Conversation.t()]
  def conversations(raw) when is_list(raw), do: Enum.map(raw, &conversation/1)

  @doc """
  One turn, from the JSON Fountain sent.

  `id` is stringified because Fountain numbers turns and the transcript keys
  on them; everything else is a string or nothing. A field that came as
  something other than a string is nothing rather than a coerced one, which
  is what `string_or_nil/1` in the transcript did before this.
  """
  @spec turn(map()) :: Turn.t()
  def turn(raw) when is_map(raw) do
    %Turn{
      id: to_string(raw["id"]),
      prompt: string_or_nil(raw["prompt"]),
      origin: string_or_nil(raw["origin"]),
      status: string_or_nil(raw["status"]),
      inserted_at: string_or_nil(raw["inserted_at"]),
      client_request_id: string_or_nil(raw["client_request_id"])
    }
  end

  @doc "A list of turns, from the JSON Fountain sent."
  @spec turns([map()]) :: [Turn.t()]
  def turns(raw) when is_list(raw), do: Enum.map(raw, &turn/1)

  @doc "One sandbox, from the JSON Fountain sent."
  @spec sandbox(map()) :: Sandbox.t()
  def sandbox(raw) when is_map(raw),
    do: %Sandbox{id: raw["id"], sprite_name: raw["sprite_name"]}

  @doc """
  The catalog, from the JSON Fountain sent.

  Total, unlike the shapes above, because the one caller wants a decision
  rather than a failure: a Fountain that served something other than an
  object offers no runtimes, which is the same answer as one that could not
  be reached. Values that are not strings are dropped rather than carried,
  because `pick_runtime/1` reads them with `String.contains?/2`.
  """
  @spec catalog(term()) :: Catalog.t()
  def catalog(raw) when is_map(raw) do
    %Catalog{runtimes: strings(raw["runtimes"]), models: models(raw["models"])}
  end

  def catalog(_other), do: Catalog.empty()

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

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_other), do: []

  # Keyed by runtime name, and the keys are Fountain's JSON object, so they
  # are already strings. A key that is not one names no runtime Ravix could
  # have asked for, so it is not kept.
  defp models(map) when is_map(map) do
    for {runtime, offered} <- map, is_binary(runtime), into: %{}, do: {runtime, strings(offered)}
  end

  defp models(_other), do: %{}
end
