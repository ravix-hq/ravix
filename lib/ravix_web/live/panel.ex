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
  """

  alias Ravix.Tracks.Diff

  @enforce_keys [:tab, :data, :error, :busy?, :file]
  defstruct @enforce_keys ++ [directories: %{}, change_count: nil]

  @type tab :: :files | :changes | :checks | :preview

  @type t :: %__MODULE__{
          tab: tab(),
          directories: %{
            optional(String.t()) =>
              Ravix.Tracks.Files.Listing.t() | {:loading, reference()} | {:error, String.t()}
          },
          data: term(),
          error: String.t() | nil,
          busy?: boolean(),
          file: Ravix.Tracks.Files.Content.t() | nil,
          change_count: {non_neg_integer(), truncated? :: boolean()} | nil
        }

  @doc "A fresh panel, on the tab a track opens with."
  @spec new() :: t()
  def new, do: %__MODULE__{tab: :files, data: nil, error: nil, busy?: false, file: nil}

  @doc "Move to `tab`. The open file belonged to the tab being left."
  @spec select(t(), tab()) :: t()
  def select(%__MODULE__{} = panel, tab), do: %__MODULE__{panel | tab: tab, file: nil}

  @doc "A read has started: nothing to show, and nothing to blame yet."
  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = panel),
    do: %__MODULE__{panel | busy?: true, error: nil, data: nil, directories: %{}}

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
