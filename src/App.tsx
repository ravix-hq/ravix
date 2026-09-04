/**
 * The shell: what is selected, what is loaded, and which of the four dialogs
 * is open.
 *
 * There is no router library and no global store. The state that matters is
 * two ids and a list, and the moment either gets a framework around it the
 * next person has to learn the framework before they can find out what a track
 * is. What there *is* instead:
 *
 *   - **The URL is the selection.** `/p/<project>/t/<track>` — so a track can
 *     be linked, reloaded and opened in a second window. An app about having
 *     four things in flight where none of them has an address is a bad joke.
 *   - **One live stream per open project**, carrying the things Fountain's own
 *     conversation stream cannot know: a track opened, a turn finished, the
 *     settings moved. The transcript has its own stream inside `TrackView`.
 *   - **Errors are toasts, never a replaced screen.** Every failure here is
 *     recoverable and losing the transcript to show a message about the file
 *     tree would be a worse outcome than the failure.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Capabilities, Project, SessionInfo, Track, TrackHeader } from "../shared/api";
import { api, ApiError, subscribe } from "./lib/api";
import { Info, Machine, Plus, X } from "./lib/icons";
import { Empty } from "./components/Empty";
import { Home, SignIn } from "./components/Home";
import { Yard } from "./components/Yard";
import { TrackView } from "./components/TrackView";
import { Inspector } from "./components/Inspector";
import { Dock } from "./components/Dock";
import { NewProject } from "./components/NewProject";
import { CreateFrom } from "./components/CreateFrom";
import { CloseTrack } from "./components/CloseTrack";
import { ProjectSettings } from "./components/ProjectSettings";
import { Search as SearchDialog } from "./components/Search";
import { People, PeopleStack } from "./components/People";

type Dialog = "new-project" | "create-from" | "settings" | "search" | "people" | "close-track" | null;

interface Route {
  projectId: string | null;
  trackId: string | null;
}

function readRoute(): Route {
  const m = /^\/p\/([^/]+)(?:\/t\/([^/]+))?/.exec(window.location.pathname);
  return { projectId: m?.[1] ?? null, trackId: m?.[2] ?? null };
}

function writeRoute(route: Route, replace = false): void {
  const path = route.projectId ? (route.trackId ? `/p/${route.projectId}/t/${route.trackId}` : `/p/${route.projectId}`) : "/";
  if (path === window.location.pathname) return;
  window.history[replace ? "replaceState" : "pushState"]({}, "", path);
}

export function App() {
  const [session, setSession] = useState<SessionInfo | null>(null);
  const [projects, setProjects] = useState<Project[]>([]);
  const [tracksByProject, setTracks] = useState<Record<string, Track[]>>({});
  const [route, setRoute] = useState<Route>(readRoute);
  const [dialog, setDialog] = useState<Dialog>(null);
  const [detail, setDetail] = useState<{ track: Track; header: TrackHeader; starters: { label: string; prompt: string }[] } | null>(null);
  const [toasts, setToasts] = useState<{ id: number; text: string; bad: boolean }[]>([]);
  const toastId = useRef(0);

  const notify = useCallback((text: string, bad = true) => {
    const id = ++toastId.current;
    setToasts((t) => [...t, { id, text, bad }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), bad ? 9000 : 4500);
  }, []);

  // ── boot ────────────────────────────────────────────────────────────

  useEffect(() => {
    void api
      .session()
      .then(setSession)
      .catch(() => notify("Could not reach the switchyard server."));
  }, [notify]);

  const reloadProjects = useCallback(async () => {
    try {
      setProjects(await api.projects());
    } catch (err) {
      if (err instanceof ApiError && err.status !== 401) notify(err.message);
    }
  }, [notify]);

  useEffect(() => {
    if (session?.viewer) void reloadProjects();
  }, [session?.viewer, reloadProjects]);

  // The browser's own back and forward buttons. Cheap to support and the first
  // thing anybody tries after opening a track from the sidebar.
  useEffect(() => {
    const onPop = () => setRoute(readRoute());
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  // ── the selected project's tracks, and its live channel ──────────────

  const reloadTracks = useCallback(
    async (projectId: string) => {
      try {
        const list = await api.tracks(projectId);
        setTracks((current) => ({ ...current, [projectId]: list }));
      } catch (err) {
        if (err instanceof ApiError) notify(err.message);
      }
    },
    [notify],
  );

  useEffect(() => {
    if (!route.projectId) return;
    void reloadTracks(route.projectId);
  }, [route.projectId, reloadTracks]);

  // ── navigation ──────────────────────────────────────────────────────

  const go = useCallback((next: Route) => {
    writeRoute(next);
    setRoute(next);
  }, []);

  const loadDetail = useCallback(
    async (trackId: string) => {
      wanted.current = trackId;
      try {
        const fresh = await api.track(trackId);
        if (wanted.current === trackId) setDetail(fresh);
      } catch (err) {
        if (wanted.current !== trackId) return;
        setDetail(null);
        // A track that has stopped existing *for this caller* — closed, or an
        // invitation withdrawn while the tab was open — answers 404, and
        // leaving the shell pointed at it shows an empty panel under a URL
        // that will never resolve again. Go home and re-read the rail, which
        // is where they can see what they do still have.
        if (err instanceof ApiError && err.status === 404) {
          go({ projectId: null, trackId: null });
          void reloadProjects();
          return;
        }
        if (err instanceof ApiError) notify(err.message);
      }
    },
    [notify, go, reloadProjects],
  );

  useEffect(() => {
    const projectId = route.projectId;
    if (!projectId) return;
    return subscribe(`/api/projects/${projectId}/stream`, {
      tracks: () => void reloadTracks(projectId),
      turn: () => void reloadTracks(projectId),
      settings: () => void reloadProjects(),
      machine: () => void reloadProjects(),
      // Somebody joined by link, or was invited or removed from another
      // window. In an app whose premise is other people doing things, a
      // membership that only refreshes when you reload is the one kind of
      // staleness that undermines the feature itself.
      people: (data) => {
        const trackId = (data as { trackId?: string } | null)?.trackId;
        if (trackId && wanted.current === trackId) void loadDetail(trackId);
      },
    });
  }, [route.projectId, reloadTracks, reloadProjects, loadDetail]);

  // Which track's answer we are still willing to accept. Selection can change
  // faster than the server answers, and a reply for the track you just left
  // must not land on top of the one you just opened.
  const wanted = useRef<string | null>(route.trackId);

  /**
   * The open track's detail, which carries the ribbon and the starters. Kept
   * separate from the list because the list is a summary and re-fetching it on
   * every stream frame must not re-render the transcript's parent.
   *
   * A function rather than only an effect because two things ask for it: the
   * selection changing, and a panel that just changed something about the
   * track it is showing.
   */

  useEffect(() => {
    const trackId = route.trackId;
    if (!trackId) {
      wanted.current = null;
      setDetail(null);
      return;
    }
    void loadDetail(trackId);
  }, [route.trackId, loadDetail]);

  const project = useMemo(() => projects.find((p) => p.id === route.projectId) ?? null, [projects, route.projectId]);

  // A project that vanished — deleted in another tab, or a stale link — should
  // land on home rather than on an empty screen with a URL that will never
  // resolve.
  useEffect(() => {
    if (route.projectId && projects.length && !project) go({ projectId: null, trackId: null });
  }, [route.projectId, projects, project, go]);

  /**
   * A track has just been opened by the dialog that opened it.
   *
   * `CreateFrom` makes the call itself rather than handing this a request,
   * because it is the thing that knows which row is in flight and has to show
   * it. So this is the arrival, not the request: refresh the rail, and go.
   */
  const trackOpened = useCallback(
    (track: Track) => {
      void reloadTracks(track.projectId);
      go({ projectId: track.projectId, trackId: track.id });
      setDialog(null);
    },
    [go, reloadTracks],
  );

  // ── keyboard ────────────────────────────────────────────────────────

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const meta = e.metaKey || e.ctrlKey;
      if (meta && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setDialog("search");
      }
      // Same gate as the button: only the owner of a project can cut a track
      // on it, so the shortcut is not a back door into a dialog that fails.
      if (meta && e.key.toLowerCase() === "n" && project?.role === "owner") {
        e.preventDefault();
        setDialog("create-from");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [project]);

  // ── render ──────────────────────────────────────────────────────────

  if (!session) return <div className="centred" />;
  if (!session.viewer) return <SignIn session={session} />;

  const capabilities: Capabilities = session.capabilities;
  const tracks = route.projectId ? (tracksByProject[route.projectId] ?? []) : [];

  return (
    <div className="app">
      <Yard
        viewer={session.viewer}
        projects={projects}
        tracksByProject={tracksByProject}
        selected={route}
        onHome={() => go({ projectId: null, trackId: null })}
        onNewProject={() => setDialog("new-project")}
        onSearch={() => setDialog("search")}
        onPickProject={(id) => go({ projectId: id, trackId: null })}
        onPickTrack={(projectId, trackId) => go({ projectId, trackId })}
        onNewTrack={(projectId) => {
          go({ projectId, trackId: null });
          setDialog("create-from");
        }}
        onProjectSettings={(projectId) => {
          go({ projectId, trackId: null });
          setDialog("settings");
        }}
      />

      <div className="stage">
        {!project ? (
          <Home
            session={session}
            projects={projects}
            onNewProject={() => setDialog("new-project")}
            onQuickStart={() => {
              void api
                .createProject({ name: "Scratch" })
                .then(async (p) => {
                  await reloadProjects();
                  go({ projectId: p.id, trackId: null });
                  setDialog("create-from");
                })
                .catch((err: unknown) => {
                  if (err instanceof ApiError) notify(err.message);
                });
            }}
            onPickProject={(id) => go({ projectId: id, trackId: null })}
          />
        ) : (
          <>
            <div className="crumbs">
              <span className="project-mark" aria-hidden="true">
                {project.name.slice(0, 1).toUpperCase()}
              </span>
              <strong>{project.name}</strong>
              {detail ? (
                <>
                  <span className="sep">›</span>
                  <span className="truncate">{detail.track.title}</span>
                  <span className="chip mono">{detail.track.branch}</span>
                </>
              ) : project.repo ? (
                <span className="chip mono">{project.repo}</span>
              ) : null}
              {detail ? <PeopleStack people={detail.track.people} onOpen={() => setDialog("people")} /> : null}
              <span className="spacer" />
              {/* A member has neither of these on the server, so they do not
                  get them here — an owner-only button that answers 403 teaches
                  people to distrust every other button beside it. */}
              {project.role === "owner" ? (
                <>
                  <button type="button" className="ghost" onClick={() => setDialog("create-from")}>
                    <Plus size={13} /> New track
                  </button>
                  <button type="button" className="ghost" onClick={() => setDialog("settings")}>
                    Settings
                  </button>
                </>
              ) : null}
              {/* Closing ends the track for everybody in it and takes the
                  worktree away, which is the owner's call — a member's way out
                  is Leave, in the people dialog. Gated on the track's role
                  rather than the project's because that is what the server
                  checks. */}
              {detail && detail.track.role === "owner" ? (
                <button type="button" className="ghost" onClick={() => setDialog("close-track")} title="Close this track">
                  <X size={13} /> Close track
                </button>
              ) : null}
            </div>

            {detail ? (
              <>
                <div className="split">
                  <TrackView
                    // A track switch is a different conversation, not a
                    // different prop. Keying on the id remounts the whole
                    // component, so the transcript, the seen-event set and the
                    // running flag all start empty and nothing from the last
                    // track can survive into this one by way of state that
                    // happened to be left behind.
                    key={detail.track.id}
                    project={project}
                    track={detail.track}
                    header={detail.header}
                    starters={detail.starters}
                    capabilities={capabilities}
                    onError={notify}
                    onOpenSettings={() => setDialog("settings")}
                    onActivity={() => void reloadTracks(project.id)}
                  />
                  <div className="inspector">
                    {/* Keyed for the same reason as the transcript: an open
                        directory, a loaded diff and a terminal's scrollback all
                        belong to one track, and a remount is a cheaper
                        guarantee of that than every panel remembering to scrub
                        itself. */}
                    <Inspector key={detail.track.id} track={detail.track} project={project} capabilities={capabilities} />
                    <Dock key={detail.track.id} track={detail.track} project={project} capabilities={capabilities} />
                  </div>
                </div>
              </>
            ) : (
              <div className="split solo">
                <div className="centre">
                  <Empty
                    icon={<Machine size={19} />}
                    title={tracks.length ? "Pick a track" : project.role === "owner" ? "No tracks yet" : "Nothing shared with you here"}
                    action={project.role === "owner" ? { label: "New track", onClick: () => setDialog("create-from") } : null}
                  >
                    {tracks.length
                      ? "Each track is its own worktree on this project's machine, with its own branch and its own conversation."
                      : project.role === "owner"
                        ? "A track is a piece of work: its own git worktree on this machine, its own branch, its own conversation. Start one from a branch, a pull request, an issue, or from nothing."
                        : "You were invited to tracks on this project rather than to the project itself, and none of them are open any more. Only its owner can start a new one."}
                  </Empty>
                </div>
              </div>
            )}
          </>
        )}
      </div>

      {dialog === "new-project" ? (
        <NewProject
          onClose={() => setDialog(null)}
          onCreated={async (created) => {
            await reloadProjects();
            go({ projectId: created.id, trackId: null });
            setDialog("create-from");
          }}
        />
      ) : null}

      {dialog === "create-from" && project ? (
        <CreateFrom project={project} onClose={() => setDialog(null)} onOpen={trackOpened} />
      ) : null}

      {dialog === "settings" && project ? (
        <ProjectSettings
          project={project}
          onClose={() => setDialog(null)}
          onChanged={() => void reloadProjects()}
          onDeleted={() => {
            setDialog(null);
            go({ projectId: null, trackId: null });
            void reloadProjects();
          }}
          onNotify={notify}
        />
      ) : null}

      {dialog === "close-track" && detail && project ? (
        <CloseTrack
          track={detail.track}
          onClose={() => setDialog(null)}
          onClosed={(message) => {
            // The row is gone, so the URL that pointed at it now answers 404.
            // Land on the project rather than home: the other tracks on this
            // machine are the thing they are most likely to want next.
            setDialog(null);
            go({ projectId: project.id, trackId: null });
            void reloadTracks(project.id);
            notify(message, false);
          }}
        />
      ) : null}

      {dialog === "people" && detail ? (
        <People
          track={detail.track}
          viewerLogin={session.viewer.login}
          onClose={() => setDialog(null)}
          onChanged={() => void loadDetail(detail.track.id)}
          onLeft={() => {
            // They are no longer on this track, so there is nothing here to
            // come back to — the next read of it is a 404. Close, go home, and
            // re-read the rail: the whole project may have left it too, if that
            // track was their only way into it.
            setDialog(null);
            go({ projectId: null, trackId: null });
            void reloadProjects();
            notify("You have left that track.", false);
          }}
        />
      ) : null}

      {dialog === "search" ? (
        <SearchDialog
          projects={projects}
          tracksByProject={tracksByProject}
          onClose={() => setDialog(null)}
          onPick={(projectId, trackId) => {
            go({ projectId, trackId });
            setDialog(null);
          }}
        />
      ) : null}

      <div className="toasts">
        {toasts.map((t) => (
          <div key={t.id} className={`toast${t.bad ? " bad" : ""}`} role="status">
            <span className="ico">
              <Info size={14} />
            </span>
            <span>{t.text}</span>
            <button
              type="button"
              className="x"
              aria-label="Dismiss"
              onClick={() => setToasts((all) => all.filter((x) => x.id !== t.id))}
            >
              <X size={12} />
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
