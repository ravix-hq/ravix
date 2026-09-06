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
import type { Capabilities, Presence, Project, SessionInfo, Track, TrackHeader } from "../shared/api";
import { api, ApiError, subscribe } from "./lib/api";
import { Info, Machine, Plus, X } from "./lib/icons";
import { Empty } from "./components/Empty";
import { Home, SignIn } from "./components/Home";
import { Yard } from "./components/Yard";
import { TrackView } from "./components/TrackView";
import { TrackName } from "./components/TrackName";
import { Inspector } from "./components/Inspector";
import { Dock } from "./components/Dock";
import { NewProject } from "./components/NewProject";
import { CreateFrom } from "./components/CreateFrom";
import { CloseTrack } from "./components/CloseTrack";
import { ProjectSettings } from "./components/ProjectSettings";
import { Search as SearchDialog } from "./components/Search";
import { People, PeopleStack, ProjectPeople } from "./components/People";
import { Vitals } from "./components/Vitals";
import { NativeViewer } from "./components/NativePreview";

type Dialog = "new-project" | "create-from" | "settings" | "search" | "people" | "project-people" | "close-track" | null;

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
  const native = /^\/native\/([a-f0-9-]{36})$/.exec(window.location.pathname);
  return native ? <NativeViewer id={native[1]!} /> : <SwitchyardApp />;
}

function SwitchyardApp() {
  const [session, setSession] = useState<SessionInfo | null>(null);
  const [signingOut, setSigningOut] = useState(false);
  const [projects, setProjects] = useState<Project[]>([]);
  const [tracksByProject, setTracks] = useState<Record<string, Track[]>>({});
  const [route, setRoute] = useState<Route>(readRoute);
  const [dialog, setDialog] = useState<Dialog>(null);
  const [detail, setDetail] = useState<{ track: Track; header: TrackHeader; starters: { label: string; prompt: string }[] } | null>(null);
  const [toasts, setToasts] = useState<{ id: number; text: string; bad: boolean }[]>([]);
  const toastId = useRef(0);

  /**
   * Who is on the open track, and who is on all the others.
   *
   * Split deliberately. Only one track's presence is on screen, and the stream
   * carries `here` for every track this person can reach — so putting the lot
   * in state would re-render the transcript every time somebody typed a
   * character in a track nobody here is looking at. The ledger keeps them
   * anyway, because it costs a map write and it means switching to a track
   * shows who is in it immediately rather than after the next sweep.
   */
  const [present, setPresent] = useState<Presence[]>([]);
  const presence = useRef<Record<string, Presence[]>>({});

  const notify = useCallback((text: string, bad = true) => {
    const id = ++toastId.current;
    setToasts((t) => [...t, { id, text, bad }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), bad ? 9000 : 4500);
  }, []);

  // ── boot ────────────────────────────────────────────────────────────

  async function signOut(): Promise<void> {
    if (signingOut) return;
    setSigningOut(true);
    try {
      await api.signOut();
      // A full navigation clears cached tracks and closes this tab's streams.
      window.location.assign("/");
    } catch (err) {
      setSigningOut(false);
      notify(err instanceof Error ? err.message : "Could not sign out. Try again.");
    }
  }

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

  /**
   * This person has seen the open track.
   *
   * The mark is a deliberate post rather than something the server infers from
   * the `GET` — its comment on `POST /read` says why, and it comes down to
   * opening a track to read the branch name not being the same as reading
   * three turns of output. So the browser is the one that has to say it, and
   * the rail is re-read afterwards because the mark is per person and only the
   * server knows what it cleared.
   *
   * A failed mark costs one dot that stays lit until the next turn, which is
   * not worth a toast on top of whatever else just went wrong; the rail is
   * reloaded either way so this stays a drop-in for a bare `reloadTracks`.
   */
  const markRead = useCallback(
    async (trackId: string, projectId: string) => {
      try {
        await api.markRead(trackId);
      } catch {
        /* the dot stays lit */
      }
      void reloadTracks(projectId);
    },
    [reloadTracks],
  );

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
        // No id means the *project's* people moved, which changes who is on
        // every track at once. Re-read the open one whichever it is, and the
        // rail besides: a project membership granted just now is a set of
        // tracks that were not in the sidebar a moment ago.
        if (!trackId) {
          void reloadProjects();
          void reloadTracks(projectId);
          if (wanted.current) void loadDetail(wanted.current);
          return;
        }
        if (wanted.current === trackId) void loadDetail(trackId);
      },
      // The whole set every time rather than a delta, which is what makes this
      // a plain assignment: there is nothing to merge and nothing to get out
      // of step with, and a frame missed while the socket reconnected is
      // corrected by the next one rather than lived with.
      here: (data) => {
        const frame = data as { trackId?: string; present?: Presence[] } | null;
        if (!frame?.trackId || !Array.isArray(frame.present)) return;
        presence.current[frame.trackId] = frame.present;
        if (wanted.current === frame.trackId) setPresent(frame.present);
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
      setPresent([]);
      return;
    }
    // Whatever the ledger last heard about this track, until the heartbeat the
    // track view is about to start brings back a set that includes us.
    setPresent(presence.current[trackId] ?? []);
    void loadDetail(trackId);
  }, [route.trackId, loadDetail]);

  // Settled, not merely fetched: a track still cutting its worktree or with a
  // turn running into it is about to say something else, and a mark taken now
  // would be older than the output by the time the dot cleared. Those two land
  // on `onActivity` below instead, when the turn is actually over. The deps are
  // the id and the status rather than `detail` itself so that a re-read of the
  // detail — somebody joining the track, say — does not re-post the mark.
  useEffect(() => {
    const open = detail?.track;
    if (!open || open.status === "opening" || open.status === "running") return;
    void markRead(open.id, open.projectId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [detail?.track.id, detail?.track.projectId, detail?.track.status, markRead]);

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
      // Same gate as the button: cutting a track needs the project rather
      // than one of its tracks, so the shortcut is not a back door into a
      // dialog that fails.
      if (meta && e.key.toLowerCase() === "n" && project && project.access !== "tracks") {
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
        signingOut={signingOut}
        onSignOut={() => void signOut()}
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
        onProjectPeople={(projectId) => {
          go({ projectId, trackId: null });
          setDialog("project-people");
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
                  {/* The name is a label and this is where it is edited. The
                      branch beside it is not: it was cut on the machine when
                      the track opened, so it stays a chip you can read. */}
                  <TrackName
                    key={detail.track.id}
                    track={detail.track}
                    viewerLogin={session.viewer.login}
                    onRenamed={() => {
                      void loadDetail(detail.track.id);
                      void reloadTracks(project.id);
                    }}
                    onError={notify}
                  />
                  <span className="chip mono">{detail.track.branch}</span>
                </>
              ) : project.repo ? (
                <span className="chip mono">{project.repo}</span>
              ) : null}
              {detail ? <PeopleStack people={detail.track.people} present={present} onOpen={() => setDialog("people")} /> : null}
              <span className="spacer" />
              {/* The machine's own numbers, and the only thing on this row
                  that is about the box rather than about the work on it. It
                  belongs to the project rather than to the track — every track
                  here shares one CPU allowance, one memory limit and one disk
                  — which is why it sits on the project's row and not in the
                  dock, where the inspector column is too narrow to hold it
                  beside three tabs. Grey, small, and at the end furthest from
                  anything that reads as an action. It renders nothing at all
                  when there is nothing to say. */}
              {detail ? <Vitals track={detail.track} /> : null}
              {/* Two different gates, because the server draws the line in two
                  different places. Cutting a track is the work and belongs to
                  anybody in the project; the settings are the machine and
                  belong to its owner. A button that answers 403 teaches people
                  to distrust every other button beside it. */}
              {project.access !== "tracks" ? (
                <button type="button" className="ghost" onClick={() => setDialog("create-from")}>
                  <Plus size={13} /> New track
                </button>
              ) : null}
              {project.role === "owner" ? (
                <button type="button" className="ghost" onClick={() => setDialog("settings")}>
                  Settings
                </button>
              ) : null}
              {/* Closing ends the track for everybody in it and takes the
                  worktree away. That is the owner's call, or the caller's own
                  if they are the one who cut it — anybody else's way out is
                  Leave, in the people dialog. The same two-part question the
                  server asks. */}
              {detail && (detail.track.role === "owner" || detail.track.createdByLogin === session.viewer.login) ? (
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
                    present={present}
                    viewerLogin={session.viewer.login}
                    onError={notify}
                    onOpenSettings={() => setDialog("settings")}
                    // A turn ending is the other moment this person has seen
                    // the track: they are looking at the reply as it lands. It
                    // also fires when they send one, which is as clear a read
                    // as there is.
                    onActivity={() => void markRead(detail.track.id, project.id)}
                  />
                  <div className="inspector">
                    {/* Keyed for the same reason as the transcript: an open
                        directory, a loaded diff and a terminal's scrollback all
                        belong to one track, and a remount is a cheaper
                        guarantee of that than every panel remembering to scrub
                        itself.
                        
                        The prefixes are not decoration. These are siblings, and
                        two siblings carrying the *same* key is a reconciliation
                        error rather than a duplicate-looking one: React cannot
                        tell which of them a keyed slot refers to, and leaves the
                        previous track's panels mounted beside the new ones. The
                        symptom is a file tree per track you have visited,
                        stacked down the side. */}
                    <Inspector key={`inspector:${detail.track.id}`} track={detail.track} project={project} capabilities={capabilities} />
                    <Dock key={`dock:${detail.track.id}`} track={detail.track} project={project} capabilities={capabilities} />
                  </div>
                </div>
              </>
            ) : (
              <div className="split solo">
                <div className="centre">
                  <Empty
                    icon={<Machine size={19} />}
                    title={tracks.length ? "Pick a track" : project.access !== "tracks" ? "No tracks yet" : "Nothing shared with you here"}
                    action={project.access !== "tracks" ? { label: "New track", onClick: () => setDialog("create-from") } : null}
                  >
                    {tracks.length
                      ? "Each track is its own worktree on this project's machine, with its own branch and its own conversation."
                      : project.access !== "tracks"
                        ? "A track is a piece of work: its own git worktree on this machine, its own branch, its own conversation. Start one from a branch, a pull request, an issue, or from nothing."
                        : "You were invited to tracks on this project rather than to the project itself, and none of them are open any more. Only somebody in the project can start a new one."}
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

      {dialog === "project-people" && project ? (
        <ProjectPeople
          project={project}
          viewerLogin={session.viewer.login}
          onClose={() => setDialog(null)}
          // Somebody let into the project just now can see tracks that were
          // not in the rail a moment ago, so this re-reads the set rather than
          // one row.
          onChanged={() => void reloadTracks(project.id)}
          onLeft={() => {
            // Not necessarily the end of their access here: a track they were
            // named on individually survives leaving the project. So re-read
            // the rail and let it say what is left, rather than assuming the
            // project has gone from it.
            setDialog(null);
            go({ projectId: null, trackId: null });
            void reloadProjects();
            notify("You have left that project.", false);
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
