defmodule RavixWeb.Live.ProjectTracks do
  @moduledoc """
  A project's tracks on the project's own page, the way a repository lists
  its branches: a list, or a branch graph.

  The graph draws the project's default branch across the top and every
  track as a branch off it, starting where the track was opened and running
  to now, or to where it was closed. Each thread is a dot on its track at the
  moment it was started, so a track with three conversations shows three.
  Nothing here is new data: the rows are the ones the rail already read
  (`Ravix.Tracks.list_many/3`), and the state each one is drawn in is
  `Ravix.Tracks.MachineState`'s, so the graph, the list, Home's strip and
  the track header say the same word.

  The window runs from the oldest track shown to now, held between one day
  and `@window_days`. A track opened before the window starts at its left
  edge, marked as clipped, rather than stretching the window until every
  recent track is a sliver.

  `WorkspaceLive` owns which view is showing (`tracks-view`) and whether
  closed tracks are loaded (`show-closed`).
  """
  use RavixWeb, :html

  alias Ravix.Tracks.{MachineState, Track}
  alias RavixWeb.LocalTime

  # The graph's geometry, in px for heights and % of the plot for x. The
  # plot stops at `@span` so the head's state label has room after "now".
  @row 56
  @main 28
  @span 86.0
  @window_days 14
  @max_ticks 8

  attr :project, :map, required: true
  attr :tracks, :list, required: true
  attr :closed, :list, default: nil, doc: "closed tracks, or nil while they are not shown"
  attr :view, :atom, values: [:graph, :list], default: :graph
  attr :reopenable, :boolean, default: false, doc: "whether a closed track can be reopened"
  attr :viewer, :any, default: nil, doc: "the person looking, to say which tracks are theirs"
  attr :more_closed, :boolean, default: false, doc: "whether older closed tracks are left out"
  attr :filter, :string, default: "", doc: "words a shown track's title or branch contains"

  attr :people, :list,
    default: [],
    doc: "who can reach the whole project (`People.list_project/2`)"

  attr :previews, :list, default: [], doc: "this project's previews that are up or coming up"
  attr :timezone, :string, default: nil
  attr :now, DateTime, default: nil

  def panel(assigns) do
    now = assigns.now || DateTime.utc_now()
    open = filter(assigns.tracks, assigns.filter)
    closed = filter(assigns.closed || [], assigns.filter)

    assigns =
      assign(assigns,
        now: now,
        tracks: open,
        closed_rows: closed,
        graph: graph(open, closed, now, assigns.timezone)
      )

    ~H"""
    <div class="project-page">
      <section id="project-tracks" class="project-tracks" aria-labelledby="project-tracks-h">
        <h2 id="project-tracks-h" class="sr-only">Tracks</h2>
        <div class="project-tracks-bar">
          <form
            id="project-tracks-filter"
            class="tracks-filter"
            role="search"
            phx-change="tracks-filter"
            phx-submit="tracks-filter"
          >
            <.icon name="search" size={16} />
            <label for="project-tracks-q" class="sr-only">Filter tracks</label>
            <input
              id="project-tracks-q"
              name="q"
              type="search"
              value={@filter}
              placeholder="Filter by title or branch"
              autocomplete="off"
              phx-debounce="150"
            />
          </form>

          <div class="segmented tracks-view" role="group" aria-label="Show tracks as">
            <button
              :for={{view, label, icon} <- [{:graph, "Graph", "branch"}, {:list, "List", "list"}]}
              type="button"
              id={"project-tracks-#{view}"}
              aria-pressed={to_string(@view == view)}
              class={if @view == view, do: "on", else: "ghost"}
              phx-click="tracks-view"
              phx-value-view={view}
            >
              <.icon name={icon} size={14} />{label}
            </button>
          </div>
          <.link
            :if={@project.access != :tracks}
            id="project-tracks-new"
            patch={"/p/#{@project.id}?new=track"}
            class="button primary"
          >
            <.icon name="plus" size={14} />New track
          </.link>
        </div>

        <div class="tracks-frame">
          <div class="tracks-frame-head">
            <span class="project-tracks-count">
              <strong>{length(@tracks)} open</strong>
              <span :if={@closed}>{length(@closed_rows)} closed</span>
            </span>
            <button
              :if={@project.access != :tracks}
              type="button"
              id="project-tracks-closed"
              class="ghost"
              aria-pressed={to_string(!is_nil(@closed))}
              phx-click="show-closed"
              phx-value-project={@project.id}
              phx-value-show={to_string(is_nil(@closed))}
            >
              {if @closed, do: "Hide closed", else: "Show closed"}
            </button>
            <span class="spacer"></span>
            <ul class="tracks-legend" aria-label="What the colours mean">
              <li><span class="dot working" aria-hidden="true"></span>Agent working</li>
              <li><span class="dot idle" aria-hidden="true"></span>Idle</li>
              <li><span class="dot starting" aria-hidden="true"></span>Starting</li>
              <li><span class="dot asleep" aria-hidden="true"></span>Asleep</li>
              <li><span class="dot error" aria-hidden="true"></span>Error</li>
              <li><span class="legend-thread" aria-hidden="true"></span>Thread started</li>
            </ul>
          </div>
          <div :if={@view == :graph} id="tracks-graph" class="tracks-graph">
            <div class="tracks-graph-inner">
              <div class="tracks-graph-labels">
                <div class="tracks-graph-axis"></div>
                <div class="tracks-graph-label">
                  <span class="chip mono">{@project.default_branch || "main"}</span>
                  <small>default branch</small>
                </div>
                <div
                  :for={row <- @graph.rows}
                  id={"tracks-graph-row-#{row.track.id}"}
                  class={["tracks-graph-label", row.closed && "closed"]}
                >
                  <div class="tracks-graph-text">
                    <div class="tracks-row-title">
                      <.mark track={row.track} />
                      <.track_link
                        project={@project}
                        track={row.track}
                        closed={row.closed}
                        label={row.label}
                        reopenable={@reopenable}
                      />
                    </div>
                    <span class="mono truncate">{row.track.branch}</span>
                  </div>
                  <span class="track-who">
                    <.owner track={row.track} viewer={@viewer} />
                    <.sharing track={row.track} viewer={@viewer} />
                  </span>
                </div>
              </div>
              <div class="tracks-graph-lanes" aria-hidden="true">
                <div class="tracks-graph-axis">
                  <span
                    :for={tick <- @graph.ticks}
                    class="tracks-graph-tick"
                    style={"left: #{tick.x}"}
                  >
                    {tick.label}
                  </span>
                </div>
                <div class="tracks-graph-plot" style={"height: #{@graph.height}px"}>
                  <span
                    :for={tick <- @graph.ticks}
                    class="tracks-graph-grid"
                    style={"left: #{tick.x}"}
                  ></span>
                  <span class="tracks-graph-main" style={"top: #{@graph.main - 1}px"}></span>
                  <div :for={row <- @graph.rows} class={["lane", row.state]}>
                    <span
                      class={["lane-fork", row.clipped && "clipped"]}
                      style={"left: #{row.x0}; top: #{@graph.main}px; height: #{row.y - @graph.main + 1}px"}
                    ></span>
                    <span
                      class="lane-bar"
                      style={"left: #{row.x0}; width: #{row.width}; top: #{row.y - 1}px"}
                    ></span>
                    <span
                      :for={x <- row.threads}
                      class="lane-thread"
                      style={"left: #{x}; top: #{row.y}px"}
                    ></span>
                    <span class="lane-head" style={"left: #{row.x1}; top: #{row.y}px"}></span>
                    <span
                      :if={!row.closed}
                      class="lane-tag"
                      style={"left: #{row.x1}; top: #{row.y}px"}
                    >
                      {row.label}
                    </span>
                  </div>
                  <span class="tracks-graph-now" style={"left: #{pct(@graph.span)}"}>
                    <small>now</small>
                  </span>
                </div>
              </div>
            </div>
            <p :if={@graph.rows == []} class="hint tracks-empty">
              No open tracks.
            </p>
          </div>

          <ul :if={@view == :list} id="tracks-list" class="tracks-list">
            <li
              :for={track <- @tracks ++ @closed_rows}
              id={"tracks-row-#{track.id}"}
              class={["tracks-row", track.closed_at && "closed"]}
            >
              <.status_dot
                status={dot_status(track)}
                label={dot_label(track)}
                title={dot_title(track)}
              />
              <div class="tracks-row-main">
                <div class="tracks-row-title">
                  <.track_link
                    project={@project}
                    track={track}
                    closed={not is_nil(track.closed_at)}
                    label={state_label(track)}
                    reopenable={@reopenable}
                  />
                  <span :if={origin(track)} class="chip">{origin(track)}</span>
                </div>
                <small class="tracks-row-meta">
                  <span class="mono">{track.branch}</span>
                  · opened {LocalTime.ago_words(track.created_at, @now)} by @{track.created_by_login}
                </small>
              </div>

              <span class="tracks-row-threads">
                {threads_label(track)}
              </span>
              <time
                :if={at = track.closed_at || track.activity_at}
                id={"tracks-row-age-#{track.id}"}
                class="tracks-row-age"
                phx-hook="RelativeTime"
                data-style="ago"
                data-title-prefix=""
                datetime={DateTime.to_iso8601(at)}
                title={LocalTime.full(at, @timezone)}
              >{LocalTime.ago_words(at, @now)}</time>
              <span class="tracks-row-state">{state_label(track)}</span>
              <span class="track-who">
                <.owner track={track} viewer={@viewer} class="tracks-row-owner" />
                <.sharing track={track} viewer={@viewer} />
              </span>
            </li>
            <li :if={@tracks == [] and @closed_rows == []} class="hint tracks-empty">
              No open tracks.
            </li>
          </ul>
        </div>

        <p :if={@closed && @closed_rows == []} class="hint">No closed tracks</p>
        <button
          :if={@closed && @more_closed}
          type="button"
          id={"closed-older-#{@project.id}"}
          class="ghost tracks-older"
          phx-click="closed-older"
          phx-value-project={@project.id}
        >
          Show older closed tracks
        </button>
      </section>
      <aside id="project-about" class="project-about" aria-label="About this project">
        <section>
          <h2>About</h2>
          <a
            :if={@project.repo}
            href={"https://github.com/#{@project.repo}"}
            class="mono"
            target="_blank"
            rel="noopener noreferrer"
          >github.com/{@project.repo}</a>
          <p :if={!@project.repo} class="hint">A scratch project, with no repository.</p>
          <small :if={@project.default_branch}>
            Tracks branch from <span class="mono">{@project.default_branch}</span>
          </small>
        </section>
        <section>
          <h2>Agent</h2>
          <span>
            {RavixWeb.AgentName.label(@project.runtime)} · {RavixWeb.ModelName.friendly(
              @project.model
            )}
          </span>
          <small>Every turn here uses @{@project.owner_login}'s subscription.</small>
        </section>
        <section :if={@people != []} id="project-people">
          <h2>People</h2>
          <ul class="project-people">
            <li :for={person <- Enum.take(@people, 12)} title={"@" <> person.login}>
              <img
                :if={person.avatar_url}
                src={person.avatar_url}
                width="32"
                height="32"
                alt={"@" <> person.login}
              />
              <span :if={!person.avatar_url} role="img" aria-label={"@" <> person.login}>
                {person.login |> String.slice(0, 2) |> String.upcase()}
              </span>
            </li>
          </ul>
          <small :if={length(@people) > 12}>and {length(@people) - 12} more</small>
        </section>
        <section id="project-previews">
          <h2>Previews</h2>
          <a
            :for={preview <- @previews}
            id={"project-preview-#{preview.track_id}"}
            href={"/preview/#{preview.track_id}"}
            target="_blank"
            rel="noopener"
            class="mono"
          >
            {preview_name(preview, @tracks)}<small :if={preview.state == :starting}> · starting</small>
          </a>
          <small :if={@previews == []}>No previews running.</small>
        </section>
      </aside>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :track, :map, required: true
  attr :closed, :boolean, required: true
  attr :label, :string, required: true
  attr :reopenable, :boolean, default: false

  defp track_link(assigns) do
    ~H"""
    <.link
      :if={!@closed}
      patch={"/p/#{@project.id}/t/#{@track.id}"}
      class="tracks-title truncate"
      title={Track.tooltip(@track)}
    >
      {Track.label(@track)}<span class="sr-only">, {@label}</span>
    </.link>
    <span :if={@closed} class="tracks-title truncate" title={Track.tooltip(@track)}>
      {Track.label(@track)}<span class="sr-only">, closed</span>
    </span>
    <button
      :if={@closed && @reopenable}
      type="button"
      id={"reopen-track-#{@track.id}"}
      class="ghost tracks-reopen"
      aria-label={"Reopen #{Track.label(@track)}"}
      phx-click={JS.push_focus() |> JS.push("reopen-track")}
      phx-value-track={@track.id}
    >Reopen</button>
    """
  end

  @doc """
  Where everything on the graph goes, from the rows alone. Open tracks first,
  newest first, then closed ones, most recently closed first; `x` values are
  CSS percentages of the plot and `y` values pixels from its top.

  Options scale it down for Home's small graphs: `row` (px per track),
  `main` (the default branch's line, px from the top) and `span` (the % of
  the width that reaches now).
  """
  @spec graph([map()], [map()], DateTime.t(), String.t() | nil, keyword()) :: map()
  def graph(open, closed, now, timezone \\ nil, opts \\ []) do
    geometry = %{
      row: Keyword.get(opts, :row, @row),
      main: Keyword.get(opts, :main, @main),
      span: Keyword.get(opts, :span, @span)
    }

    rows =
      Enum.sort_by(open, &unix(&1.created_at), :desc) ++
        Enum.sort_by(closed, &unix(&1.closed_at), :desc)

    start = window_start(rows, now)
    x = fn at -> position(at, start, now, geometry.span) end

    %{
      main: geometry.main,
      span: geometry.span,
      height: geometry.row * (length(rows) + 1),
      ticks: ticks(start, now, timezone, x),
      rows:
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {track, i} -> lane(track, i, x, start, geometry) end)
    }
  end

  defp lane(track, i, x, start, geometry) do
    closed = not is_nil(track.closed_at)
    x0 = x.(track.created_at)
    x1 = if closed, do: x.(track.closed_at), else: geometry.span

    %{
      track: track,
      closed: closed,
      clipped: DateTime.compare(track.created_at, start) == :lt,
      state: if(closed, do: "closed", else: state(track)),
      label: if(closed, do: "Closed", else: state_label(track)),
      y: geometry.main + i * geometry.row,
      x0: pct(x0),
      x1: pct(x1),
      width: pct(max(x1 - x0, 0.0)),
      threads: thread_marks(track.threads, x)
    }
  end

  defp thread_marks(threads, x) do
    for %{created_at: %DateTime{} = at} <- threads, do: pct(x.(at))
  end

  # The oldest row's opening, held to at least a day before now and at most
  # `@window_days`.
  defp window_start(rows, now) do
    earliest = rows |> Enum.map(& &1.created_at) |> Enum.min(DateTime, fn -> now end)
    floor = DateTime.add(now, -@window_days * 86_400)
    ceiling = DateTime.add(now, -86_400)

    earliest
    |> max_time(floor)
    |> min_time(ceiling)
  end

  # A day's midnight in the viewer's zone is where its tick goes; with more
  # days than `@max_ticks`, every nth one is labelled.
  defp ticks(start, now, timezone, x) do
    first = LocalTime.in_zone(start, timezone) |> DateTime.to_date() |> Date.add(1)
    last = LocalTime.in_zone(now, timezone) |> DateTime.to_date()

    if Date.compare(first, last) == :gt do
      []
    else
      days = Date.range(first, last) |> Enum.to_list()
      step = max(ceil(length(days) / @max_ticks), 1)

      days
      |> Enum.take_every(step)
      |> Enum.map(fn date ->
        midnight = midnight(date, timezone)
        %{x: pct(x.(midnight)), label: Calendar.strftime(date, "%b %-d")}
      end)
    end
  end

  defp midnight(date, zone) when is_binary(zone) do
    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, at} -> at
      {:ambiguous, at, _} -> at
      {:gap, _, at} -> at
      {:error, _} -> DateTime.new!(date, ~T[00:00:00])
    end
  end

  defp midnight(date, _zone), do: DateTime.new!(date, ~T[00:00:00])

  defp position(nil, _start, _now, _span), do: 0.0

  defp position(at, start, now, span) do
    seconds = max(DateTime.diff(now, start, :second), 1)
    share = DateTime.diff(at, start, :second) / seconds
    Float.round(min(max(share, 0.0), 1.0) * span, 2)
  end

  defp pct(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2) <> "%"

  defp unix(nil), do: 0
  defp unix(at), do: DateTime.to_unix(at, :microsecond)

  defp max_time(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)
  defp min_time(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  @doc """
  A track's unread mark, as the rail drew it (RAV-96): a reply nobody has
  read, or only a comment, on a track whose machine has nothing more pressing
  to say (Idle or Asleep). Nothing otherwise. Home's recent tracks draw it
  too.
  """
  attr :track, :map, required: true

  def mark(assigns) do
    assigns = assign(assigns, :marker, marker(assigns.track))

    ~H"""
    <.status_dot
      :if={@marker}
      status={to_string(@marker)}
      label={marker_label(@marker)}
      title={marker_label(@marker)}
    />
    """
  end

  @doc """
  A track's dot: its unread mark when it has one, else its state, named for
  a screen reader and in the tooltip. The sidebar's Active tracks draw it.
  """
  attr :track, :map, required: true

  def dot(assigns) do
    ~H"""
    <.status_dot
      status={dot_status(@track)}
      label={dot_label(@track)}
      title={dot_title(@track)}
    />
    """
  end

  # A preview is named for its track, else its host.
  defp preview_name(preview, tracks) do
    case Enum.find(tracks, &(&1.id == preview.track_id)) do
      nil -> preview.hostname || "Preview"
      track -> Track.label(track)
    end
  end

  # The filter's words, each found in the title or the branch, any case.
  defp filter(rows, words) when words in [nil, ""], do: rows

  defp filter(rows, words) do
    terms = words |> String.downcase() |> String.split()

    Enum.filter(rows, fn track ->
      text = String.downcase("#{Track.label(track)} #{track.branch}")
      Enum.all?(terms, &String.contains?(text, &1))
    end)
  end

  @doc """
  Whose a track is, as an icon before its name: yours, shared with you by
  its creator, or private (its creator and the people they invite). The
  icon is named for a screen reader and in the tooltip. A private track
  keeps its `.track-private` lock, as everywhere else.
  """
  attr :track, :map, required: true
  attr :viewer, :any, required: true

  def sharing(assigns) do
    assigns = assign(assigns, :sharing, sharing_of(assigns.track, assigns.viewer))

    ~H"""
    <span
      class={[
        "track-sharing",
        "sharing-#{@sharing.kind}",
        @sharing.kind == :private && "track-private"
      ]}
      role="img"
      tabindex="0"
      aria-label={@sharing.label}
      data-tip={@sharing.label}
    ><.icon name={@sharing.icon} size={14} /></span>
    """
  end

  @doc """
  Who started a track: their avatar, with "You" or their login in the
  tooltip and for a screen reader.
  """
  attr :track, :map, required: true
  attr :viewer, :any, required: true
  attr :class, :any, default: nil

  def owner(assigns) do
    assigns = assign(assigns, :yours?, yours?(assigns.track, assigns.viewer))

    ~H"""
    <span
      class={["track-owner", @class]}
      data-tip={"Started by " <> if(@yours?, do: "you", else: "@#{@track.created_by_login}")}
    >
      <img
        :if={@track.creator_avatar_url}
        src={@track.creator_avatar_url}
        alt=""
        loading="lazy"
        width="22"
        height="22"
      />
      <span :if={!@track.creator_avatar_url} class="track-owner-mark" aria-hidden="true">
        {(@track.created_by_login || "?") |> String.slice(0, 2) |> String.upcase()}
      </span>
      <span class="sr-only">{if @yours?, do: "You", else: "@#{@track.created_by_login}"}</span>
    </span>
    """
  end

  defp yours?(_track, nil), do: false
  defp yours?(track, viewer), do: Ravix.Accounts.Access.created_by?(viewer, track)

  defp sharing_of(%{visibility: :private} = track, viewer) do
    who = if yours?(track, viewer), do: "you", else: "@#{track.created_by_login}"

    %{
      kind: :private,
      icon: "lock",
      label: "Private: only #{who} and the people invited"
    }
  end

  defp sharing_of(track, viewer) do
    if yours?(track, viewer),
      do: %{kind: :yours, icon: "person", label: "Yours, open to the project"},
      else: %{
        kind: :shared,
        icon: "add-person",
        label: "Shared with you by @#{track.created_by_login}"
      }
  end

  @doc "`:unread` for an unread reply, `:commented` for only a comment, or nil."
  @spec marker(map()) :: :unread | :commented | nil
  def marker(%{closed_at: %DateTime{}}), do: nil

  def marker(track) do
    case MachineState.marker(MachineState.of(track), Map.get(track, :unread) == true) do
      :unread -> if reply_unread?(track), do: :unread, else: :commented
      _state -> nil
    end
  end

  defp reply_unread?(track) do
    case Map.get(track, :reply_unread) do
      nil -> Map.get(track, :unread) == true
      value -> value
    end
  end

  defp marker_label(:unread), do: "Unread reply"
  defp marker_label(:commented), do: "New comment"

  defp dot_status(track), do: to_string(marker(track) || state(track))

  defp dot_label(track) do
    case marker(track) do
      nil -> state_label(track)
      marker -> "#{marker_label(marker)} · #{state_label(track)}"
    end
  end

  # The tooltip says why, when the state has more to say than its word:
  # "Error: This track's machine failed."
  defp dot_title(%{closed_at: %DateTime{}} = track), do: dot_label(track)

  defp dot_title(track) do
    case MachineState.of(track).detail do
      detail when is_binary(detail) and detail != "" -> "#{dot_label(track)}: #{detail}"
      _ -> dot_label(track)
    end
  end

  @doc "The state a row is drawn in: `MachineState`'s, or closed."
  @spec state(map()) :: String.t()
  def state(%{closed_at: %DateTime{}}), do: "closed"
  def state(track), do: track |> MachineState.of() |> Map.fetch!(:state) |> to_string()

  defp state_label(%{closed_at: %DateTime{}}), do: "Closed"

  defp state_label(track),
    do: track |> MachineState.of() |> Map.fetch!(:state) |> MachineState.label()

  defp threads_label(%{threads: [_]}), do: "1 thread"
  defp threads_label(%{threads: threads}), do: "#{length(threads)} threads"

  @doc "What a track was started from, in a few words, or nil for a blank one."
  @spec origin(map()) :: String.t() | nil
  def origin(%{origin: %{kind: :pr, number: n}}) when is_integer(n), do: "PR ##{n}"
  def origin(%{origin: %{kind: :issue, number: n}}) when is_integer(n), do: "Issue ##{n}"
  def origin(%{origin: %{kind: :plan}}), do: "Plan item"
  def origin(%{origin: %{kind: :branch}}), do: "Branch"
  def origin(_track), do: nil
end
