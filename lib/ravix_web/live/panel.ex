defmodule RavixWeb.Live.Panel do
  @moduledoc """
  The inspector panel's whole state: which tab, what it is showing, and
  whether it is still fetching.

  One assign rather than the five it was (`panel`, `panel_data`,
  `panel_error`, `panel_busy`, `file`), which is what a `useState` per field
  looks like once it has been transcribed into `assign/2`. They only ever
  change together -- opening a tab clears the file and the error, a load
  clears the data and sets busy, an answer clears busy -- and five assigns
  is five chances to do four of those.

  `tab` is an atom. The browser sends the word as a string and `TrackLive`'s
  `handle_event/3` converts it through `@tabs`, a fixed table, so nothing
  past the boundary compares strings and nothing anywhere can mint an atom
  from what a client typed.

  `change_count` is how many files the last diff read found, kept apart from
  `data` so the Changes tab can wear it while another tab is showing. It is
  only ever what a read already answered -- nothing fetches a diff to draw
  it -- and `nil` means "not known", which is what it goes back to when a
  turn ends somewhere this panel was not looking. A truncated diff counts
  the files it got to, so the count is a floor and says so.

  `cache` is what Files and Changes last showed, kept while another tab is
  up so that coming back to one is instant: `select/2` puts the cached view
  on screen and the caller refreshes it in the background with
  `reloading/1`, rather than blanking the tab for a round trip to the
  machine. A folder that was still loading when its tab was left is folded
  on the way into the cache, because its answer will find no one waiting
  for it. Nothing here orders the refreshes; `TrackLive` names each tab's
  read after the tab (`{:panel, tab}`), and LiveView keeps only the latest
  task under a name, so an older answer cannot land over a newer one.
  """

  alias Ravix.Tracks.Diff

  @enforce_keys [:tab, :data, :error, :busy?, :file]
  defstruct @enforce_keys ++ [directories: %{}, metadata: %{}, change_count: nil, cache: %{}]

  @type tab :: :files | :changes | :checks | :preview

  @typedoc "A cached tab: its data and, for Files, the folders open in it."
  @type view :: %{data: term(), directories: map()}

  # The tabs whose last answer is worth showing again at once. Checks read
  # GitHub and Preview a process, and both are only true as of now.
  @cached [:files, :changes]

  @type t :: %__MODULE__{
          tab: tab(),
          metadata: %{optional(String.t()) => reference()},
          directories: %{
            optional(String.t()) =>
              Ravix.Tracks.Files.Listing.t() | {:loading, reference()} | {:error, String.t()}
          },
          data: term(),
          error: String.t() | nil,
          busy?: boolean(),
          file: Ravix.Tracks.Files.Content.t() | nil,
          change_count: {non_neg_integer(), truncated? :: boolean()} | nil,
          cache: %{optional(tab()) => view()}
        }

  @doc "A fresh panel, on the tab a track opens with."
  @spec new() :: t()
  def new, do: %__MODULE__{tab: :files, data: nil, error: nil, busy?: false, file: nil}

  @doc """
  Move to `tab`. The open file belonged to the tab being left. What the tab
  being left was showing goes into the cache, and what the cache holds for
  `tab`, if anything, comes out of it onto the screen.
  """
  @spec select(t(), tab()) :: t()
  def select(%__MODULE__{} = panel, tab) do
    panel = %__MODULE__{panel | cache: stash(panel)}

    case panel.cache do
      %{^tab => view} ->
        %__MODULE__{
          panel
          | tab: tab,
            file: nil,
            error: nil,
            busy?: false,
            data: view.data,
            directories: view.directories,
            metadata: %{}
        }

      %{} ->
        %__MODULE__{panel | tab: tab, file: nil}
    end
  end

  @doc "Whether `select/2` put a cached view on screen for the current tab."
  @spec cached?(t()) :: boolean()
  def cached?(%__MODULE__{tab: tab, cache: cache, data: data}),
    do: match?(%{^tab => %{data: ^data}}, cache) and data != nil

  @doc """
  A background read of `tab` landed while another tab is showing: keep it
  for when `tab` is next selected. Only a tab already cached is updated, so
  a refresh cannot resurrect one the panel has since forgotten.
  """
  @spec cache(t(), tab(), term()) :: t()
  def cache(%__MODULE__{cache: cache} = panel, tab, data) when is_map_key(cache, tab) do
    panel = %__MODULE__{panel | cache: put_in(cache, [tab, :data], data)}

    case data do
      %Diff{changes: changes, truncated: truncated} ->
        %__MODULE__{panel | change_count: {length(changes), truncated}}

      _other ->
        panel
    end
  end

  def cache(%__MODULE__{} = panel, _tab, _data), do: panel

  @doc "Forget every cached tab: what they held can no longer be shown."
  @spec forget_cache(t()) :: t()
  def forget_cache(%__MODULE__{} = panel), do: %__MODULE__{panel | cache: %{}}

  defp stash(%__MODULE__{tab: tab, data: data, cache: cache} = panel)
       when tab in @cached and is_struct(data) do
    folders = Map.reject(panel.directories, fn {_path, value} -> match?({:loading, _}, value) end)
    Map.put(cache, tab, %{data: data, directories: folders})
  end

  defp stash(%__MODULE__{cache: cache}), do: cache

  @doc "A read has started: nothing to show, and nothing to blame yet."
  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = panel),
    do: %__MODULE__{panel | busy?: true, error: nil, data: nil, directories: %{}, metadata: %{}}

  @doc """
  A read of the same tab has started, and what is showing stays until it
  lands. For a refresh nobody asked for, where blanking the list somebody is
  reading would be the only visible effect.
  """
  @spec reloading(t()) :: t()
  def reloading(%__MODULE__{} = panel), do: %__MODULE__{panel | busy?: true, error: nil}

  @doc "The read landed. A diff also says how many files it found."
  @spec loaded(t(), term()) :: t()
  def loaded(%__MODULE__{} = panel, %Diff{changes: changes, truncated: truncated} = data),
    do: %__MODULE__{panel | busy?: false, data: data, change_count: {length(changes), truncated}}

  def loaded(%__MODULE__{} = panel, data), do: %__MODULE__{panel | busy?: false, data: data}

  @doc "The last diff read may no longer be true: forget its count."
  @spec forget_changes(t()) :: t()
  def forget_changes(%__MODULE__{} = panel), do: %__MODULE__{panel | change_count: nil}

  @doc "The read was refused, with the sentence to show for it."
  @spec failed(t(), String.t()) :: t()
  def failed(%__MODULE__{} = panel, message),
    do: %__MODULE__{panel | busy?: false, error: message}

  @doc "Whatever was in flight is no longer, without saying anything about it."
  @spec settled(t()) :: t()
  def settled(%__MODULE__{} = panel), do: %__MODULE__{panel | busy?: false}

  @doc "Show one file inside the current tab."
  @spec open_file(t(), Ravix.Tracks.Files.Content.t()) :: t()
  def open_file(%__MODULE__{} = panel, file), do: %__MODULE__{panel | file: file}

  @doc "Close whatever file is open."
  @spec close_file(t()) :: t()
  def close_file(%__MODULE__{} = panel), do: %__MODULE__{panel | file: nil}
end
