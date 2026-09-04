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
import { Home, Plus, Search, Settings } from "../lib/icons";

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
              </div>

              {tracks.map((track, i) => (
                <button
                  key={track.id}
                  type="button"
                  className={`track-row${selected.trackId === track.id ? " on" : ""}`}
                  onClick={() => props.onPickTrack(project.id, track.id)}
                  title={`${track.title} — ${track.branch}`}
                >
                  <span className="track-num">{i + 1}</span>
                  <span className="truncate">{track.title}</span>
                  <span className="spacer" />
                  {track.stale ? (
                    <span className="chip" title="This track opened before the project's settings changed">
                      older
                    </span>
                  ) : null}
                  <span className={`dot ${track.status}`} aria-label={track.status} />
                </button>
              ))}

              {active ? (
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
        <span className="badge-free">switchyard</span>
        <span className="spacer" />
        <a className="dimmer" style={{ fontSize: 11 }} href="/api/auth/install">
          repo access
        </a>
      </div>
    </nav>
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
  return <span className={`dot ${state === "ready" ? "ready" : ""}`} title={label} aria-label={label} />;
}
