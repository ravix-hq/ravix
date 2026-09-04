/**
 * The yard: the left rail, and the app's only navigation.
 *
 * It is a two-level tree — projects, and the tracks running on each — and the
 * shape is the argument. A flat list of conversations would be the easy thing
 * and would lose the fact that four tracks under one project share a machine,
 * a disk and a one-turn-at-a-time lock. The rail drawn down the left of each
 * track group is there to say that: these are branches off one line.
 *
 * A project with no open track still shows, collapsed to its own row, because
 * a project is a machine that exists whether or not anybody is working in it.
 */
import type { Project, Track } from "../../shared/api";
import { Home, Plus, Search, Settings, Spinner } from "../lib/icons";
import { ThemePicker } from "./ThemePicker";

export interface YardProps {
  viewer: { login: string; name: string | null; avatarUrl: string | null } | null;
  projects: Project[];
  tracksByProject: Record<string, Track[]>;
  selected: { projectId: string | null; trackId: string | null };
  onHome: () => void;
  onNewProject: () => void;
  onSearch: () => void;
  onPickProject: (projectId: string) => void;
  onPickTrack: (projectId: string, trackId: string) => void;
  onNewTrack: (projectId: string) => void;
  onProjectSettings: (projectId: string) => void;
}

export function Yard(props: YardProps) {
  const { viewer, projects, tracksByProject, selected } = props;
  return (
    <nav className="yard" aria-label="Projects and tracks">
      <div className="yard-top">
        {viewer?.avatarUrl ? (
          <img className="avatar" src={viewer.avatarUrl} alt="" />
        ) : (
          <span className="avatar" aria-hidden="true" />
        )}
        <span className="yard-who truncate">
          <strong className="truncate">{viewer?.name ?? viewer?.login ?? "Switchyard"}</strong>
          <small className="truncate">{viewer ? `@${viewer.login}` : "not signed in"}</small>
        </span>
      </div>

      <div className="yard-nav">
        <button
          type="button"
          className={`yard-item${!selected.projectId ? " on" : ""}`}
          onClick={props.onHome}
        >
          <span className="ico">
            <Home size={14} />
          </span>
          Home
        </button>
        <button type="button" className="yard-item" onClick={props.onNewProject}>
          <span className="ico">
            <Plus size={14} />
          </span>
          Add a project
        </button>
        <button type="button" className="yard-item" onClick={props.onSearch}>
          <span className="ico">
            <Search size={14} />
          </span>
          Search
        </button>
      </div>

      <div className="yard-scroll">
        <div className="yard-label">
          <span>Projects</span>
          <span className="row">
            <button type="button" className="x" onClick={props.onNewProject} aria-label="Add a project" title="Add a project">
              <Plus size={13} />
            </button>
          </span>
        </div>

        {projects.length === 0 ? (
          <p className="fine" style={{ padding: "2px 9px" }}>
            No projects yet. Add one and switchyard builds it a machine.
          </p>
        ) : null}

        {projects.map((project) => {
          const tracks = tracksByProject[project.id] ?? [];
          const active = selected.projectId === project.id;
          // A project you were invited *into* — by way of one of its tracks —
          // shows the tracks you can reach and nothing else. Cutting a track
          // and opening the settings are both refused by the server for a
          // member, so neither appears rather than appearing and failing.
          const owner = project.role === "owner";
          return (
            <div key={project.id} style={{ marginBottom: 6 }}>
              <div className="row" style={{ gap: 0 }}>
                <button
                  type="button"
                  className={`project-row${active && !selected.trackId ? " on" : ""}`}
                  onClick={() => props.onPickProject(project.id)}
                >
                  <span className="project-mark" aria-hidden="true">
                    {project.name.slice(0, 1).toUpperCase()}
                  </span>
                  <strong className="truncate">{project.name}</strong>
                  <span className="spacer" />
                  <MachineDot project={project} />
                </button>
                {owner ? (
                  <button
                    type="button"
                    className="x"
                    style={{ padding: "0 4px" }}
                    onClick={() => props.onNewTrack(project.id)}
                    aria-label={`New track in ${project.name}`}
                    title="New track"
                  >
                    <Plus size={13} />
                  </button>
                ) : null}
              </div>

              {tracks.map((track, i) => {
                // The track you are looking at is never unread, whatever the
                // list says: the read mark is a round trip behind the click,
                // and a row that lights up the moment you open it teaches
                // people that the dot means nothing.
                const unread = track.unread && selected.trackId !== track.id;
                return (
                  <button
                    key={track.id}
                    type="button"
                    className={`track-row${selected.trackId === track.id ? " on" : ""}${unread ? " unread" : ""}`}
                    onClick={() => props.onPickTrack(project.id, track.id)}
                    title={rowTitle(track, unread)}
                  >
                    {/* Unread at one end of the row, activity at the other.
                        They were one dot before — a ring around the status —
                        and the two states a person actually scans for are
                        exactly the two that can be true at once, which is the
                        case that made the ring unreadable. Two ends, two
                        marks, and neither has to be told apart from the other
                        by colour: a pip where the number was, an arc where the
                        dot is. The number is the thing that gives way because
                        it is an ordinal nothing else refers to. */}
                    <span className="track-num">{unread ? <i className="pip" aria-label="unread" /> : i + 1}</span>
                    <span className="truncate">{track.title}</span>
                    <span className="spacer" />
                    {track.stale ? (
                      <span className="chip" title="This track opened before the project's settings changed">
                        older
                      </span>
                    ) : null}
                    <TrackMark track={track} />
                  </button>
                );
              })}

              {active && owner ? (
                <button type="button" className="track-row" onClick={() => props.onProjectSettings(project.id)}>
                  <span className="track-num" />
                  <span className="ico">
                    <Settings size={12} />
                  </span>
                  <span className="dim">Project settings</span>
                </button>
              ) : null}
            </div>
          );
        })}
      </div>

      <div className="yard-foot">
        <ThemePicker />
        <div className="yard-foot-row">
          <span className="badge-free">switchyard</span>
          <span className="spacer" />
          <a className="dimmer" style={{ fontSize: 11 }} href="/api/auth/install">
            repo access
          </a>
        </div>
      </div>
    </nav>
  );
}

/** Whether the machine is mid-turn for this track — cutting it, or thinking. */
const busy = (status: Track["status"]) => status === "running" || status === "opening";

const activity = (status: Track["status"]) =>
  status === "running" ? "a turn is running" : status === "opening" ? "cutting the worktree" : status;

const rowTitle = (track: Track, unread: boolean) =>
  [track.title, track.branch, busy(track.status) ? activity(track.status) : null, unread ? "unread" : null]
    .filter(Boolean)
    .join(" — ");

/**
 * The right end of a track row: what the machine is doing there now.
 *
 * A turn running is not a brighter shade of sitting still, so it is not drawn
 * as one. It is an arc going round where the other states are a circle staying
 * put — a difference of shape and of motion, which is what survives being six
 * pixels wide, being read by somebody who cannot separate the accent from the
 * green, and sharing a row with the unread pip at the other end.
 *
 * Both marks live in a box the same size, so a turn starting does not shove the
 * title under the pointer sideways.
 */
function TrackMark({ track }: { track: Track }) {
  const label = activity(track.status);
  if (busy(track.status)) {
    return (
      <span className={`track-mark spin ${track.status}`} aria-label={label}>
        <Spinner size={12} />
      </span>
    );
  }
  return (
    <span className="track-mark">
      <span className={`dot ${track.status}`} aria-label={label} />
    </span>
  );
}

/**
 * One dot for the machine, and it says whether the disk exists rather than
 * whether anything is running. A project with a machine that has gone to sleep
 * is not in trouble — Fountain wakes it on the next turn — so a sleeping box
 * and a missing one must not look the same.
 */
function MachineDot({ project }: { project: Project }) {
  const state = project.machine.status;
  const label = state === "none" ? "no machine yet" : state === "ready" ? "machine up" : state;
  // The same box the track rows end in, so the two kinds of row share one
  // column of marks down the right of the rail rather than nearly sharing it.
  return (
    <span className="track-mark">
      <span className={`dot ${state === "ready" ? "ready" : ""}`} title={label} aria-label={label} />
    </span>
  );
}
