defmodule RavixWeb.Live.HomeProjects do
  @moduledoc """
  Home, laid out as a code host's dashboard in three columns.

  Down the left, whose workspace this is and the person's sections, which
  narrow the list (Manage sections files projects into them), and the open
  tracks. In the middle, the projects, listed the way an account lists
  its repositories: each one's name, whether it is private, its repository,
  its agent, how many tracks are open and when one last moved, and a pill per
  open track in the state `Ravix.Tracks.MachineState` gives it. Down the
  left, under the sections, the open tracks newest first; down the right,
  what needs you.

  Everything drawn comes from what the rail has already read, so Home asks
  nothing new of the database or of Fountain.
  """
  use RavixWeb, :html

  alias Ravix.Tracks.{MachineState, Track}
  alias RavixWeb.LocalTime

  attr :workspace, :string, required: true
  attr :kind, :string, required: true, doc: "Personal or Team"
  attr :count, :integer, required: true

  attr :groups, :list,
    required: true,
    doc: "`{key, name, projects}` for each section with projects in it"

  attr :selected, :string, default: nil
  attr :viewer, :any, required: true, doc: "the person looking, to say which tracks are theirs"
  attr :active, :list, default: [], doc: "`{project, track}` for each open track, newest first"
  attr :loaded, :boolean, default: true

  def side(assigns) do
    ~H"""
    <aside id="home-side" class="home-side" aria-label="Sections">
      <div class="home-who">
        <span class="home-who-mark" aria-hidden="true">
          {@workspace |> String.trim_leading("@") |> String.first() |> String.upcase()}
        </span>
        <span class="home-who-text">
          <strong class="truncate">{@workspace}</strong>
          <small>{@kind} · {@count} {if @count == 1, do: "project", else: "projects"}</small>
        </span>
      </div>
      <nav class="home-sections" aria-labelledby="home-sections-h">
        <h2 id="home-sections-h" class="home-label">Sections</h2>
        <button
          type="button"
          id="home-section-all"
          class={["home-section", is_nil(@selected) && "on"]}
          aria-pressed={to_string(is_nil(@selected))}
          phx-click="home-section"
          phx-value-section=""
        >
          <span>All projects</span><small class="mono">{@count}</small>
        </button>
        <button
          :for={{key, name, projects} <- @groups}
          :if={length(@groups) > 1}
          type="button"
          id={"home-section-#{key}"}
          class={["home-section", @selected == key && "on"]}
          aria-pressed={to_string(@selected == key)}
          phx-click="home-section"
          phx-value-section={key}
        >
          <span class="truncate">{name}</span><small class="mono">{length(projects)}</small>
        </button>
        <button
          type="button"
          id="manage-sections"
          class="home-section home-section-add"
          phx-click={JS.push_focus() |> JS.push("dialog")}
          phx-value-name="sections"
        >
          <.icon name="plus" size={14} /><span>Manage sections</span>
        </button>
      </nav>
      <section class="home-active" aria-labelledby="home-active-h">
        <h2 id="home-active-h" class="home-label">Active tracks</h2>
        <ul :if={@active != []} id="home-active" class="home-active-list">
          <li :for={{project, track} <- @active}>
            <.link
              id={"home-active-#{track.id}"}
              patch={"/p/#{project.id}/t/#{track.id}"}
              class="home-active-row"
              title={Track.tooltip(track)}
            >
              <RavixWeb.Live.ProjectTracks.dot track={track} />
              <span class="home-activity-text">
                <span class="truncate">{Track.label(track)}</span>
                <small class="home-active-meta truncate"><.project_name project={project} /></small>
              </span>
              <span class="track-who">
                <small class="home-active-state">{state_word(track)}</small>
                <RavixWeb.Live.ProjectTracks.owner track={track} viewer={@viewer} />
                <RavixWeb.Live.ProjectTracks.sharing track={track} viewer={@viewer} />
              </span>
            </.link>
          </li>
        </ul>
        <p :if={@loaded && @active == []} id="home-active-empty" class="hint">No open tracks.</p>
      </section>
    </aside>
    """
  end

  attr :heading, :string, required: true
  attr :groups, :list, required: true
  attr :tracks, :map, required: true
  attr :selected, :string, default: nil
  attr :sort, :atom, values: [:recent, :name], default: :recent
  attr :attention, :map, required: true, doc: "each project's count of tracks that need you"
  attr :previews, :map, default: %{}, doc: "each project's previews that are up or coming up"
  attr :errors, :any, required: true, doc: "projects whose tracks could not be read"
  attr :loading, :any, required: true, doc: "projects whose tracks are being read again"

  def list(assigns) do
    shown =
      for(
        {key, _name, projects} <- assigns.groups,
        is_nil(assigns.selected) or key == assigns.selected,
        project <- projects,
        do: project
      )
      |> sort(assigns.sort, assigns.tracks)

    assigns = assign(assigns, shown: shown)

    ~H"""
    <section id="home-projects" class="home-projects" aria-labelledby="home-projects-h">
      <div class="home-projects-head">
        <h1 id="home-projects-h">{@heading}</h1>
        <button
          type="button"
          id="home-sort"
          class="secondary"
          phx-click="home-sort"
          phx-value-sort={if @sort == :recent, do: "name", else: "recent"}
        >
          Sort: {if @sort == :recent, do: "Recent activity", else: "Name"}
        </button>
        <button
          type="button"
          id="home-add-repository"
          class="primary"
          phx-click={JS.push_focus() |> JS.push("dialog")}
          phx-value-name="new-project"
        >
          <.icon name="plus" size={14} />New project
        </button>
      </div>
      <ul class="home-project-list">
        <li :for={project <- @shown} id={"home-project-#{project.id}"} class="home-project">
          <div class="home-project-main">
            <div class="home-project-title">
              <.icon name="document" size={16} />
              <.link
                id={"project-link-#{project.id}"}
                patch={"/p/#{project.id}"}
                class="home-project-name"
              >
                <.project_name project={project} />
              </.link>
              <span class="chip">{if project.repo_private, do: "Private", else: "Public"}</span>
              <span :if={project.repo} class="chip mono">{project.repo}</span>
              <span
                :if={Map.get(@attention, project.id, 0) > 0}
                class="badge"
                aria-label={need_you(Map.get(@attention, project.id, 0))}
                title={need_you(Map.get(@attention, project.id, 0))}
              >{Map.get(@attention, project.id, 0)}</span>
            </div>
            <small class="home-project-meta">
              <span class="home-project-agent">
                <span class="home-agent-dot" aria-hidden="true"></span>{RavixWeb.AgentName.label(
                  project.runtime
                )}
              </span>
              <span>{open_label(@tracks[project.id])}</span>
              <span>{previews_label(Map.get(@previews, project.id, []))}</span>
              <span :if={updated(@tracks[project.id])}>Updated {updated(@tracks[project.id])}</span>
            </small>
          </div>
          <div class="home-project-lanes">
            <div :if={MapSet.member?(@errors, project.id)} role="status">
              <small>Couldn't load tracks</small>
              <button
                type="button"
                class="ghost"
                phx-click="retry-tracks"
                phx-value-id={project.id}
                disabled={MapSet.member?(@loading, project.id)}
              >{if MapSet.member?(@loading, project.id), do: "Retrying…", else: "Retry"}</button>
            </div>
            <small :if={!MapSet.member?(@errors, project.id)} class="home-label-small">
              Live tracks
            </small>
            <span :if={!MapSet.member?(@errors, project.id)} class="lane-strip" aria-hidden="true">
              <span
                :for={track <- open_rows(@tracks[project.id])}
                class={["lane-pill", state(track)]}
              ></span>
            </span>
            <small :if={!MapSet.member?(@errors, project.id)}>{summary(@tracks[project.id])}</small>
          </div>
          <.link
            :if={project.access != :tracks}
            patch={"/p/#{project.id}?new=track"}
            id={"new-track-#{project.id}"}
            phx-click={JS.push_focus()}
            class="icon-button ghost home-project-new"
            aria-label={"New track in #{project.display_name}"}
            data-tip="New track"
          >
            <.icon name="plus" size={14} />
          </.link>
        </li>
      </ul>
      <p :if={@shown == []} class="hint">No projects in this section.</p>
    </section>
    """
  end

  attr :needs, :list, required: true, doc: "`{project, track, reason}` for each that needs you"

  def activity(assigns) do
    ~H"""
    <aside id="home-activity" class="home-activity" aria-label="Activity">
      <section aria-labelledby="home-needs-h">
        <h2 id="home-needs-h">Needs you</h2>
        <ul :if={@needs != []} id="home-needs" class="home-box home-needs">
          <li :for={{project, track, reason} <- @needs}>
            <.link
              id={"home-needs-#{track.id}"}
              patch={"/p/#{project.id}/t/#{track.id}"}
              class="home-activity-row"
            >
              <RavixWeb.Live.ProjectTracks.dot track={track} />
              <span class="home-activity-text">
                <span><strong>{Track.label(track)}</strong> {reason}</span>
                <small class="truncate"><.project_name project={project} /></small>
              </span>
            </.link>
          </li>
        </ul>
        <p :if={@needs == []} id="home-needs-empty" class="hint">Nothing needs you.</p>
      </section>
    </aside>
    """
  end

  defp sort(projects, :name, _tracks),
    do: Enum.sort_by(projects, &String.downcase(&1.display_name))

  defp sort(projects, :recent, tracks),
    do: Enum.sort_by(projects, &(-activity_key(latest(tracks[&1.id]))))

  defp latest(rows) do
    rows
    |> open_rows()
    |> Enum.map(& &1.activity_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp activity_key(nil), do: 0
  defp activity_key(at), do: DateTime.to_unix(at, :microsecond)

  defp updated(rows) do
    case latest(rows) do
      nil -> nil
      at -> LocalTime.ago_words(at)
    end
  end

  defp open_rows(rows) when is_list(rows), do: Enum.filter(rows, &is_nil(&1.closed_at))
  defp open_rows(_unavailable), do: []

  defp open_label(rows) do
    case length(open_rows(rows)) do
      1 -> "1 open track"
      n -> "#{n} open tracks"
    end
  end

  defp previews_label([_]), do: "1 preview"
  defp previews_label(previews), do: "#{length(previews)} previews"

  defp state_word(track), do: MachineState.label(MachineState.of(track).state)

  defp state(track), do: track |> MachineState.of() |> Map.fetch!(:state) |> to_string()

  # The badge counts the tracks the Inbox would list (RAV-96), not how many
  # tracks there are.
  defp need_you(1), do: "1 track needs you"
  defp need_you(count), do: "#{count} tracks need you"

  @doc "How many open tracks are in each state, in words: \"2 Working · 1 Asleep\"."
  @spec summary([map()] | term()) :: String.t()
  def summary(rows) do
    case open_rows(rows) do
      [] ->
        "No open tracks"

      open ->
        open
        |> Enum.map(&MachineState.of(&1).state)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_state, n} -> -n end)
        |> Enum.map_join(" · ", fn {state, n} -> "#{n} #{MachineState.label(state)}" end)
    end
  end
end
