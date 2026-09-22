defmodule Ravix.PromptQueue.Body do
  @moduledoc """
  What a queued prompt actually says: the text, and the images attached to it.

  `prompt_queue.body` is a `jsonb` column, and until now its two keys were
  spelled as strings wherever they were read. The furthest of those is
  `Ravix.PromptQueue.Server.post/4`, the last thing that happens before a
  prompt reaches Fountain:

      payload = row.id |> Store.get() |> Map.fetch!(:body) || %{}
      Fountain.prompt(client, track.conversation_id, text, payload["images"] || [])

  `payload["images"]` answers `nil` for a key that is not there, `|| []`
  turns that into "no attachments", and the delivery succeeds. So a rename
  or a typo on either side of that column is a prompt delivered without the
  images somebody attached to it, with nothing saying so --- and the row is
  then marked `sent` and its body released, so there is nothing left to
  notice it with either.

  The column is decoded here, once, into a struct with `@enforce_keys`, and
  nothing past this module addresses a field by a string. Same boundary rule
  `Ravix.Fountain.Shapes` and `Ravix.GitHub.Shapes` follow for provider
  payloads, applied to Ravix's own.

  ## Both directions

  `encode/1` writes the two string keys the column has always held and
  `decode/1` reads them back. The asymmetry worth naming is that the two
  were never the same shape in memory: an image went *in* as
  `%{data: ..., media_type: ...}` with atom keys, and came back out of
  Postgres with string ones. Both spellings decode.

  `decode(nil)` is an empty body rather than a failure. A row that has been
  delivered or cancelled has had its body released on purpose --- the
  receipt outlives the megabytes --- and asking one what it said is a
  reasonable thing to do.
  """

  defmodule Image do
    @moduledoc """
    One image attached to a prompt: base64 `data` and its `media_type`.

    Encoded straight into Fountain's prompt request, which is why these two
    names are Fountain's rather than Ravix's.
    """

    alias Ravix.PromptQueue.Body

    # `Ravix.Fountain.prompt/4` hands the list to Jason as the request body.
    @derive {Jason.Encoder, only: [:data, :media_type]}

    @enforce_keys [:data, :media_type]
    defstruct [:data, :media_type]

    @type t :: %__MODULE__{data: String.t(), media_type: String.t()}

    @doc "An image as the `body` column stores it."
    @spec encode(t()) :: map()
    def encode(%__MODULE__{} = image),
      do: %{"data" => image.data, "media_type" => image.media_type}

    @doc """
    An image, as a one-element list, or an empty one for an entry that is
    not a usable image.

    A list rather than `{:ok, _} | :error` so `decode/1` above can be a
    `flat_map`: a stored entry that cannot be read is dropped, because the
    alternative is failing a delivery over an attachment nobody can do
    anything about by then. What reaches this column has already been
    through `Ravix.Tracks.prompt/3`.
    """
    @spec decode(term()) :: [t()]
    def decode(%__MODULE__{} = image), do: [image]

    def decode(%{} = map) do
      data = Body.field(map, "data", :data)
      media_type = Body.field(map, "media_type", :media_type)

      if is_binary(data) and is_binary(media_type),
        do: [%__MODULE__{data: data, media_type: media_type}],
        else: []
    end

    def decode(_other), do: []
  end

  @enforce_keys [:prompt, :images]
  defstruct prompt: "", images: []

  @type t :: %__MODULE__{prompt: String.t(), images: [Image.t()]}

  @doc "Supply working-directory identity to a blank additional conversation."
  def in_thread(prompt, %{thread_id: thread_id, track_id: track_id}, track)
      when is_binary(thread_id) and thread_id != track_id do
    "[ravix] This conversation shares track #{track.id}. Your working directory is " <>
      "#{track.workdir} and its branch is #{track.branch}. Work only in this directory. " <>
      "The track is already open; do not create another worktree or branch.\n\n" <> prompt
  end

  def in_thread(prompt, _row, _track), do: prompt

  @doc "An empty body: no text, no attachments."
  @spec empty() :: t()
  def empty, do: %__MODULE__{prompt: "", images: []}

  @doc "A body as the `body` column stores it."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = body) do
    %{
      "prompt" => body.prompt,
      "images" => Enum.map(body.images, &Image.encode/1)
    }
  end

  @doc """
  The body a `body` column holds, or an empty one for a row whose body has
  been released.
  """
  @spec decode(map() | nil) :: t()
  def decode(nil), do: empty()

  def decode(%__MODULE__{} = body), do: body

  def decode(%{} = map) do
    prompt = field(map, "prompt", :prompt)

    %__MODULE__{
      prompt: if(is_binary(prompt), do: prompt, else: ""),
      images: map |> field("images", :images) |> images()
    }
  end

  @doc false
  # Both spellings are real: a freshly built body holds atom keys and one
  # read back from Postgres holds strings. The atom is passed rather than
  # derived, so no unbounded `String.to_atom/1` runs on stored data.
  @spec field(map(), String.t(), atom()) :: term()
  def field(map, string_key, atom_key) do
    case Map.fetch(map, string_key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key)
    end
  end

  defp images(list) when is_list(list), do: Enum.flat_map(list, &Image.decode/1)
  defp images(_other), do: []
end
