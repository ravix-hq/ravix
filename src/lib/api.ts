/**
 * The browser's whole world.
 *
 * Every call here is same-origin, cookie-authenticated and typed against
 * `shared/api.ts`. There is no Fountain client in this app, no GitHub client
 * and no Sprites client — the browser holds no credential for any of them, so
 * it could not build one if it wanted to. That is the wall described at the
 * top of `shared/api.ts`, expressed as the fact that this file is the only
 * place a `fetch` appears.
 */
import type {
  BranchRef,
  ChecksReport,
  DiffReport,
  ExecResult,
  FileContent,
  FileListing,
  IssueRef,
  Person,
  Project,
  ProjectSettings,
  PullRef,
  RepoRef,
  SessionInfo,
  Track,
  TrackHeader,
  TrackOriginInfo,
  TranscriptPage,
} from "../../shared/api";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(path, {
    ...init,
    headers: { accept: "application/json", ...(init.body ? { "content-type": "application/json" } : {}), ...init.headers },
  });
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  let parsed: unknown = null;
  if (text) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = null;
    }
  }
  if (!res.ok) {
    const body = (parsed ?? {}) as { error?: string; message?: string };
    throw new ApiError(res.status, body.error ?? "error", body.message ?? `Something went wrong (${res.status}).`);
  }
  return (parsed as { data: T }).data;
}

const post = <T>(path: string, body?: unknown) =>
  call<T>(path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) });

export const api = {
  // ── the shell ──────────────────────────────────────────────────────
  session: () => call<SessionInfo>("/api/session"),
  signOut: () => post<{ ok: true }>("/api/auth/signout"),

  // ── GitHub ─────────────────────────────────────────────────────────
  repos: (installation?: number) =>
    call<{ installations: { id: number; account: string; avatarUrl: string | null }[]; selected?: number; repos: RepoRef[] }>(
      `/api/github/repos${installation ? `?installation=${installation}` : ""}`,
    ),

  // ── projects ───────────────────────────────────────────────────────
  projects: () => call<Project[]>("/api/projects"),
  project: (id: string) => call<Project>(`/api/projects/${id}`),
  createProject: (body: { repo?: string | null; installationId?: number | null; name?: string }) =>
    post<Project>("/api/projects", body),
  deleteProject: (id: string) => call<{ ok: true }>(`/api/projects/${id}`, { method: "DELETE" }),
  settings: (id: string) => call<ProjectSettings>(`/api/projects/${id}/settings`),
  saveSettings: (id: string, body: Partial<ProjectSettings> & { secret?: { store: "env" | "vault"; key: string; value: string } }) =>
    call<{ rev: number }>(`/api/projects/${id}/settings`, { method: "PUT", body: JSON.stringify(body) }),
  rebuild: (id: string) => post<{ removed: string[]; failed: { what: string; why: string }[] }>(`/api/projects/${id}/rebuild`),

  branches: (projectId: string) => call<BranchRef[]>(`/api/projects/${projectId}/refs?kind=branches`),
  pulls: (projectId: string) => call<PullRef[]>(`/api/projects/${projectId}/refs?kind=pulls`),
  issues: (projectId: string) => call<IssueRef[]>(`/api/projects/${projectId}/refs?kind=issues`),

  // ── tracks ─────────────────────────────────────────────────────────
  tracks: (projectId: string) => call<Track[]>(`/api/projects/${projectId}/tracks`),
  track: (id: string) =>
    call<{ track: Track; header: TrackHeader; starters: { label: string; prompt: string }[] }>(`/api/tracks/${id}`),
  openTrack: (projectId: string, body: { title?: string; slug?: string; origin?: Partial<TrackOriginInfo> }) =>
    post<Track>(`/api/projects/${projectId}/tracks`, body),
  renameTrack: (id: string, title: string) => call<{ ok: true }>(`/api/tracks/${id}`, { method: "PATCH", body: JSON.stringify({ title }) }),
  closeTrack: (id: string, force = false) => call<{ ok: true }>(`/api/tracks/${id}${force ? "?force=1" : ""}`, { method: "DELETE" }),
  prompt: (id: string, text: string) => post<{ ok: true }>(`/api/tracks/${id}/prompt`, { prompt: text }),
  interrupt: (id: string) => post<{ ok: true }>(`/api/tracks/${id}/interrupt`),
  retry: (id: string) => post<{ ok: true }>(`/api/tracks/${id}/retry`),
  events: (id: string) => call<TranscriptPage>(`/api/tracks/${id}/events`),

  // ── the machine, through a track ───────────────────────────────────
  files: (id: string, path?: string) =>
    call<FileListing>(`/api/tracks/${id}/files${path ? `?path=${encodeURIComponent(path)}` : ""}`),
  file: (id: string, path: string) => call<FileContent>(`/api/tracks/${id}/file?path=${encodeURIComponent(path)}`),
  diff: (id: string) => call<DiffReport>(`/api/tracks/${id}/diff`),
  checks: (id: string) => call<ChecksReport>(`/api/tracks/${id}/checks`),
  openPull: (id: string, body: { title?: string; base?: string; body?: string; draft?: boolean }) =>
    post<PullRef & { url: string }>(`/api/tracks/${id}/pull`, body),

  execStatus: (id: string) =>
    call<{ available: boolean; why: "no_token" | "no_machine" | "no_sprite" | "unreachable" | null; cwd: string }>(
      `/api/tracks/${id}/exec`,
    ),
  exec: (id: string, command: string, cwd?: string) => post<ExecResult>(`/api/tracks/${id}/exec`, { command, cwd }),

  // ── working on a track with somebody else ──────────────────────────
  /** Autocomplete over everyone who has signed in here. One character is enough. */
  findPeople: (q: string) => call<Person[]>(`/api/users?q=${encodeURIComponent(q)}`),
  people: (trackId: string) => call<Person[]>(`/api/tracks/${trackId}/people`),
  invite: (trackId: string, login: string) => post<Person[]>(`/api/tracks/${trackId}/people`, { login }),
  /** The owner removing somebody, or a member removing themselves. */
  uninvite: (trackId: string, login: string) =>
    call<Person[] | undefined>(`/api/tracks/${trackId}/people/${encodeURIComponent(login)}`, { method: "DELETE" }),
};

/**
 * A server-sent stream, as a subscription.
 *
 * `EventSource` rather than `fetch` + a hand-rolled parser, which is what the
 * rest of this suite uses. The reason the suite hand-rolls it is that Fountain
 * needs an `Authorization` header and `EventSource` cannot send one — here the
 * stream is same-origin and authenticated by cookie, so the browser's own
 * implementation applies, reconnection and all.
 */
export function subscribe(url: string, handlers: Record<string, (data: unknown) => void>): () => void {
  const source = new EventSource(url, { withCredentials: true });
  const bound: [string, EventListener][] = [];
  for (const [event, fn] of Object.entries(handlers)) {
    const listener: EventListener = (e) => {
      const raw = (e as MessageEvent).data;
      if (typeof raw !== "string") return;
      try {
        fn(JSON.parse(raw));
      } catch {
        // A heartbeat, or a frame from a Fountain version that sends something
        // this build does not know. Neither is worth an exception.
      }
    };
    source.addEventListener(event, listener);
    bound.push([event, listener]);
  }
  return () => {
    for (const [event, listener] of bound) source.removeEventListener(event, listener);
    source.close();
  };
}
