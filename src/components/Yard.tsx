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
import { useState } from "react";
import type { Project, Track } from "../../shared/api";
import { AddPerson, Chevron, Home, Plus, Search, Settings, Spinner } from "../lib/icons";
import { TrackPull } from "./TrackPull";
import { ThemePicker } from "./ThemePicker";

export interface YardProps {
  github?: boolean;
  inboxActive?: boolean;
  inboxCount?: number;
  onInbox?: () => void;
  viewer: { login: string; name: string | null; avatarUrl: string | null } | null;
  projects: Project[];
  tracksByProject: Record<string, Track[]>;
  selected: { projectId: string | null; trackId: string | null };
  onHome: () => void;
  onNewProject: () => void;
  onSearch: () => void;
  onSignOut: () => void;
  signingOut: boolean;
  onPickProject: (projectId: string) => void;
  onPickTrack: (projectId: string, trackId: string) => void;
  onNewTrack: (projectId: string) => void;
  onProjectSettings: (projectId: string) => void;
  onProjectPeople: (projectId: string) => void;
}

export function Yard(props: YardProps) {
  const { viewer, projects, tracksByProject, selected } = props;
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
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
        <button type="button" className={`yard-item${props.inboxActive ? " on" : ""}`} onClick={props.onInbox}>
          <span className="ico" aria-hidden="true">▤</span>
          Inbox <span className="spacer" /><span className="chip">{props.inboxCount ?? 0}</span>
        </button>
        <button
          type="button"
          className={`yard-item${!selected.projectId && !props.inboxActive ? " on" : ""}`}
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
          const expanded = !collapsed[project.id];
          // Three kinds of row, and the controls differ because the server
          // differs. An owner gets everything. Somebody invited to the whole
          // project can cut tracks and see who else is here, but not touch the
          // settings. Somebody invited to one *track* gets the tracks they can
          // reach and nothing else — no new track, no settings, and no people
          // list, since they are not in a membership that has one.
          const owner = project.role === "owner";
          const inProject = project.access === "owner" || project.access === "project";
          return (
            <div key={project.id} style={{ marginBottom: 6 }}>
              <div className="row" style={{ gap: 0 }}>
                <button
                  type="button"
                  className="x"
                  aria-label={`${expanded ? "Collapse" : "Expand"} ${project.name}`}
                  aria-expanded={expanded}
                  aria-controls={`project-tracks-${project.id}`}
                  title={`${expanded ? "Collapse" : "Expand"} project`}
                  onClick={() => setCollapsed((current) => ({ ...current, [project.id]: !current[project.id] }))}
                >
                  <Chevron size={13} open={expanded} />
                </button>
                <button
                  type="button"
                  className={`project-row${active && !selected.trackId ? " on" : ""}`}
                  onClick={() => {
                    setCollapsed((current) => ({ ...current, [project.id]: false }));
                    props.onPickProject(project.id);
                  }}
                >
                  <span className="project-mark" aria-hidden="true">
                    {project.name.slice(0, 1).toUpperCase()}
                  </span>
                  <strong className="truncate">{project.name}</strong>
                  <span className="spacer" />
                </button>
                {inProject ? (
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

              <div id={`project-tracks-${project.id}`} hidden={!expanded}>
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
                      <span className="track-num"><TrackActivity track={track} unread={unread} ordinal={i + 1} /></span>
                      <span className="truncate">{track.title}</span>
                      <span className="spacer" />
                      {track.stale ? (
                        <span className="chip" title="This track opened before the project's settings changed">
                          older
                        </span>
                      ) : null}
                      {props.github && project.repo ? <TrackPull track={track} /> : null}
                    </button>
                  );
                })}

                {active && inProject ? (
                  <button type="button" className="track-row" onClick={() => props.onProjectPeople(project.id)}>
                    <span className="track-num" />
                    <span className="ico">
                      <AddPerson size={12} />
                    </span>
                    <span className="dim">People</span>
                  </button>
                ) : null}

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
            </div>
          );
        })}
      </div>

      <div className="yard-foot">
        <button type="button" className="ghost" onClick={props.onSignOut} disabled={props.signingOut}>
          {props.signingOut ? "Signing out…" : "Sign out"}
        </button>
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

/** Running takes precedence over unread output until the turn finishes. */
export function TrackActivity({ track, unread, ordinal }: { track: Pick<Track, "status">; unread: boolean; ordinal?: number }) {
  const state = trackActivity(track.status, unread);
  if (state.kind === "idle") return ordinal ?? null;
  return (
    <span className={`track-activity ${state.kind}`} role="img" aria-label={state.label} title={state.detail}>
      {state.kind === "busy" ? <span className="track-mark spin" aria-hidden="true"><Spinner size={12} /></span>
        : track.status === "failed" ? <span className="track-activity-symbol" aria-hidden="true">!</span>
        : <i className="pip" aria-hidden="true" />}
    </span>
  );
}

function trackActivity(status: Track["status"], unread: boolean) {
  if (status === "running") return { kind: "busy", label: "Running", detail: "The agent is working" };
  if (status === "opening") return { kind: "busy", label: "Opening", detail: "Preparing the track's worktree" };
  if (status === "failed") return { kind: "attention", label: "Needs attention", detail: "The turn failed — open the conversation to review" };
  if (status === "closed") return { kind: "idle", label: "Closed", detail: "This track is closed" };
  if (unread) return { kind: "attention", label: "Needs attention", detail: "The agent finished and has an unread reply" };
  return { kind: "idle", label: "Idle", detail: "No turn is running and all replies have been read" };
}

const rowTitle = (track: Track, unread: boolean) =>
  [track.title, track.branch, trackActivity(track.status, unread).detail].filter(Boolean).join(" — ");
