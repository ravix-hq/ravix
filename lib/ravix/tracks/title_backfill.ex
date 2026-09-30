defmodule Ravix.Tracks.TitleBackfill do
  @moduledoc """
  The one-time data step that names the tracks automatic titles (RAV-48)
  never reached (RAV-83): those opened before RAV-48, and those opened
  through MCP, whose first prompt was accepted inside a transaction the
  titler could not see into.

  Each open track still titled with its branch, and never named by anyone
  (`title_source` nil), is considered, oldest first, through its default
  thread:

    * a thread that already has an automatic title gives the track that
      title, as `Ravix.Tracks.Titling` would have;
    * a thread a person named is left alone and reported: a thread's name
      is not the track's, and nobody asked for this one to be;
    * otherwise the thread and track are titled from the first prompt a
      person wrote there (`Ravix.PromptQueue.Store.first_person_prompt/2`),
      read by `Ravix.Tracks.Title.from_prompt/1`; a track with no such
      prompt, or one with no words in it, is reported and left alone.

  A dry run by default: `run(apply: false)` works out the plan and writes
  nothing. `run(apply: true)` writes each title through
  `Ravix.Tracks.Store.auto_title/3`, the same compare-and-set as the live
  path, so a rename landing meanwhile wins and a second run changes
  nothing. The summary holds ids and outcomes, never a title: those are
  read out of people's prompts.

  Needs the `Ravix.Repo` and nothing else: `Ravix.Release.retitle_tracks/1`
  runs it without starting the application. An operator step, run as no
  user: every row it touches goes through a `Store`. Nothing is published,
  so a page already open shows the new name on its next read.
  """

  alias Ravix.Tracks.{Store, Thread, Title, Track}

  @type action :: :retitle | :no_thread | :thread_named | :no_prompt | :no_words
  @type line :: %{
          id: String.t(),
          project_id: String.t(),
          action: action(),
          title: String.t() | nil,
          result: :retitled | :stale | nil,
          track: Track.t(),
          thread: Thread.t() | nil
        }
  @type summary :: %{applied: boolean(), tracks: [line()]}

  @doc "Work out the titles, and write them when `apply: true`."
  @spec run(keyword()) :: {:ok, summary()}
  def run(opts \\ []) do
    lines = Enum.map(Store.branch_titled_tracks(), &line/1)

    if Keyword.get(opts, :apply, false) do
      {:ok, %{applied: true, tracks: Enum.map(lines, &%{&1 | result: write(&1)})}}
    else
      {:ok, %{applied: false, tracks: lines}}
    end
  end

  defp line(%Track{} = track) do
    {action, title, thread} = plan(track, Store.thread(track.id))

    %{
      id: track.id,
      project_id: track.project_id,
      action: action,
      title: title,
      result: nil,
      track: track,
      thread: thread
    }
  end

  defp plan(_track, nil), do: {:no_thread, nil, nil}
  defp plan(_track, %Thread{title_source: :auto} = t), do: {:retitle, t.title, t}
  defp plan(_track, %Thread{title_source: :manual} = t), do: {:thread_named, nil, t}

  defp plan(track, %Thread{} = thread) do
    # ownership: no door -- the operator data step; the prompt is read to
    # title the track it was sent on, as `Ravix.Tracks.Titling` reads it.
    case Ravix.PromptQueue.Store.first_person_prompt(track.id, thread.id) do
      nil ->
        {:no_prompt, nil, thread}

      {_id, prompt} ->
        case Title.from_prompt(prompt) do
          nil -> {:no_words, nil, thread}
          title -> {:retitle, title, thread}
        end
    end
  end

  defp write(%{action: :retitle, thread: thread, track: track, title: title}) do
    case Store.auto_title(thread, track, title) do
      :ok -> if retitled?(track.id, title), do: :retitled, else: :stale
      :stale -> :stale
    end
  end

  defp write(_left_alone), do: nil

  # `auto_title/3` passes over a track renamed since the plan and still
  # titles its thread; only the track row says whether it took the title.
  defp retitled?(id, title), do: match?(%Track{title: ^title}, Store.get_track(id))

  @doc "The summary as lines of text, for the task's output. Ids only, no titles."
  @spec format(summary()) :: [String.t()]
  def format(%{applied: applied, tracks: lines}) do
    mode = if applied, do: "Applied", else: "Dry run (pass --apply to write)"

    tally =
      case lines |> Enum.frequencies_by(& &1.action) |> Enum.sort() do
        [] -> "no open track is still titled with its branch"
        counts -> Enum.map_join(counts, ", ", fn {action, n} -> "#{n} #{action}" end)
      end

    ["#{mode}: #{tally}"] ++
      Enum.map(lines, fn line ->
        "  #{line.id} (project #{line.project_id}): " <>
          describe(line.action) <> outcome(line.result)
      end)
  end

  defp describe(:retitle), do: "retitle"
  defp describe(:no_thread), do: "left alone: no default thread"
  defp describe(:thread_named), do: "left alone: a person named its thread"
  defp describe(:no_prompt), do: "left alone: nobody has prompted it"
  defp describe(:no_words), do: "left alone: its first prompt has no words to title it by"

  defp outcome(nil), do: ""
  defp outcome(:retitled), do: " -> retitled"
  defp outcome(:stale), do: " -> skipped at write: renamed or retitled since the plan"
end
