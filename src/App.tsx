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
import { ProjectSettings } from "./components/ProjectSettings";
import { Search as SearchDialog } from "./components/Search";

type Dialog = "new-project" | "create-from" | "settings" | "search" | null;

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

  useEffect(() => {
    const projectId = route.projectId;
    if (!projectId) return;
    return subscribe(`/api/projects/${projectId}/stream`, {
      tracks: () => void reloadTracks(projectId),
      turn: () => void reloadTracks(projectId),
      settings: () => void reloadProjects(),
      machine: () => void reloadProjects(),
    });
  }, [route.projectId, reloadTracks, reloadProjects]);

  // The open track's detail, which carries the ribbon and the starters. Kept
  // separate from the list because the list is a summary and re-fetching it on
  // every stream frame must not re-render the transcript's parent.
  useEffect(() => {
    const trackId = route.trackId;
    if (!trackId) {
      setDetail(null);
      return;
    }
    let alive = true;
    void api
      .track(trackId)
      .then((d) => alive && setDetail(d))
      .catch((err: unknown) => {
        if (!alive) return;
        setDetail(null);
        if (err instanceof ApiError) notify(err.message);
      });
    return () => {
      alive = false;
    };
  }, [route.trackId, notify]);

  // ── navigation ──────────────────────────────────────────────────────

  const go = useCallback((next: Route) => {
    writeRoute(next);
    setRoute(next);
  }, []);

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
      if (meta && e.key.toLowerCase() === "n" && route.projectId) {
        e.preventDefault();
        setDialog("create-from");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [route.projectId]);

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
              <span className="spacer" />
              <button type="button" className="ghost" onClick={() => setDialog("create-from")}>
                <Plus size={13} /> New track
              </button>
              <button type="button" className="ghost" onClick={() => setDialog("settings")}>
                Settings
              </button>
            </div>

            {detail ? (
              <>
                <div className="split">
                  <TrackView
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
                    <Inspector track={detail.track} project={project} capabilities={capabilities} />
                    <Dock track={detail.track} project={project} capabilities={capabilities} />
                  </div>
                </div>
              </>
            ) : (
              <div className="split solo">
                <div className="centre">
                  <Empty
                    icon={<Machine size={19} />}
                    title={tracks.length ? "Pick a track" : "No tracks yet"}
                    action={{ label: "New track", onClick: () => setDialog("create-from") }}
                  >
                    {tracks.length
                      ? "Each track is its own worktree on this project's machine, with its own branch and its own conversation."
                      : "A track is a piece of work: its own git worktree on this machine, its own branch, its own conversation. Start one from a branch, a pull request, an issue, or from nothing."}
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
