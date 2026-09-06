import type { RunnerInfo } from '../../shared/runners';
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
  InviteLink,
  IssueRef,
  Person,
  Presence,
  Project,
  ProjectSettings,
  PullRef,
  QueuedPrompt,
  RepoRef,
  SessionInfo,
  Track,
  TrackHeader,
  TrackOriginInfo,
  TranscriptPage,
  VitalsReport,
} from "../../shared/api";

import type { PreviewConfig, PreviewInfo } from "../../shared/previews";
import type { NativeInfo, NativePlatform } from "../../shared/native-preview";
import type { BrowserInfo, BrowserResult, BrowserCheckpoint } from "../../shared/browser";

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

// Files and changes mount together. Share the wake request so entering a
// track does not run several commands. Nothing is sent to the agent.
const waking = new Map<string, Promise<void>>();

async function readMachine<T>(trackId: string, path: string): Promise<T> {
  try {
    return await call<T>(path);
  } catch (err) {
    if (!(err instanceof ApiError) || err.code !== "sandbox_not_ready") throw err;
    if (!/\bsuspended\b/i.test(err.message)) {
      throw new ApiError(409, "machine_starting", "The machine is starting. Try again in a moment.");
    }
  }

  let wake = waking.get(trackId);
  if (!wake) {
    wake = post<ExecResult>(`/api/tracks/${trackId}/exec`, { command: ":", timeoutSec: 30 })
      .then((result) => {
        if (result.code !== 0) throw new Error("Wake failed");
      })
      .finally(() => { waking.delete(trackId); });
    waking.set(trackId, wake);
  }
  try {
    await wake;
  } catch {
    throw new ApiError(409, "machine_asleep", "The machine is asleep. Try waking it again, or send a message in this track to resume work.");
  }
  try {
    return await call<T>(path);
  } catch (err) {
    if (err instanceof ApiError && err.code === "sandbox_not_ready") {
      throw new ApiError(409, "machine_asleep", "The machine is still getting ready. Try again in a moment, or send a message in this track to resume work.");
    }
    throw err;
  }
}

export const api = {
  browser: (trackId: string) => call<BrowserInfo>(`/api/tracks/${trackId}/browser`),
  browserAction: (trackId: string, action: "start" | "stop" | "delete-checkpoint", clientId: string, checkpointId?: string) => post<BrowserInfo>(`/api/tracks/${trackId}/browser/${action}`, { clientId, checkpointId }),
  browserCommand: (trackId: string, clientId: string, command: Record<string, unknown>) => post<BrowserResult>(`/api/tracks/${trackId}/browser/command`, { ...command, clientId }),
  browserCheckpoint: (trackId: string, clientId: string, label: string) => post<BrowserCheckpoint>(`/api/tracks/${trackId}/browser/checkpoint`, { clientId, label }),
  browserRestore: (trackId: string, clientId: string, checkpointId: string) => post<BrowserResult>(`/api/tracks/${trackId}/browser/restore`, { clientId, checkpointId }),
  nativePreview: (trackId: string) => call<{available:boolean;platforms:NativePlatform[];runners:RunnerInfo[];session:NativeInfo|null}>(`/api/tracks/${trackId}/native`),
  startNativePreview: (trackId: string, platform: NativePlatform = "android") => post<NativeInfo>(`/api/tracks/${trackId}/native/start`, {platform,requestId:crypto.randomUUID()}),
  pairNativeRunner: (trackId: string) => post<{code:string;expiresAt:number}>(`/api/tracks/${trackId}/native/runner-pair`),
  revokeNativeRunner: (runnerId: string) => post<{ok:true}>(`/api/native/runners/${runnerId}/revoke`),
  stopNativePreview: (trackId: string) => post<{ok:true}>(`/api/tracks/${trackId}/native/stop`),
  nativeSession: (id: string) => call<NativeInfo & {trackUrl:string}>(`/api/native/sessions/${id}`),
  preview: (trackId: string) => call<PreviewInfo>(`/api/tracks/${trackId}/preview`),
  previewAction: (trackId: string, action: "open" | "restart" | "stop" | "logs") => post<PreviewInfo & { openUrl?: string }>(`/api/tracks/${trackId}/preview/${action}`),
  savePreview: (trackId: string, config: PreviewConfig | null) => call<PreviewInfo>(`/api/tracks/${trackId}/preview/config`, { method: "PUT", body: JSON.stringify({ config }) }),
  previewDefaults: (projectId: string) => call<PreviewConfig | null>(`/api/projects/${projectId}/preview`),
  savePreviewDefaults: (projectId: string, config: PreviewConfig | null) => call<PreviewConfig | null>(`/api/projects/${projectId}/preview`, { method: "PUT", body: JSON.stringify({ config }) }),
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
  closeTrack: (id: string, opts: { force?: boolean; deleteBranch?: boolean } = {}) => {
    const qs = new URLSearchParams();
    if (opts.force) qs.set("force", "1");
    if (opts.deleteBranch) qs.set("branch", "1");
    const q = qs.toString();
    return call<{ ok: true }>(`/api/tracks/${id}${q ? `?${q}` : ""}`, { method: "DELETE" });
  },
  prompt: (id: string, text: string, images: { data: string; media_type: string }[] = [], requestId: string = crypto.randomUUID()) =>
    post<{ ok: true }>(`/api/tracks/${id}/prompt`, { requestId, prompt: text, ...(images.length ? { images } : {}) }),
  promptQueue: (id: string) => call<QueuedPrompt[]>(`/api/tracks/${id}/queue`),
  cancelPrompt: (id: string, promptId: string) => call<{ ok: true }>(`/api/tracks/${id}/queue/${promptId}`, { method: "DELETE" }),
  retryPrompt: (id: string, promptId: string) => post<{ ok: true }>(`/api/tracks/${id}/queue/${promptId}/retry`),
  /** This person has seen the track up to now. Clears its unread dot. */
  markRead: (id: string) => post<{ ok: true }>(`/api/tracks/${id}/read`),
  /**
   * Still here, and possibly mid-sentence.
   *
   * `typing` is a pulse the server gives three seconds, not a state to turn
   * off — so the composer pings while keys are being pressed and simply stops,
   * and a browser that dies mid-word does not leave a claim behind.
   */
  presence: (id: string, opts: { typing?: boolean; leaving?: boolean } = {}) =>
    post<Presence[]>(`/api/tracks/${id}/presence`, opts),
  interrupt: (id: string) => post<{ ok: true }>(`/api/tracks/${id}/interrupt`),
  retry: (id: string) => post<{ ok: true }>(`/api/tracks/${id}/retry`),
  events: (id: string) => call<TranscriptPage>(`/api/tracks/${id}/events`),

  // ── the machine, through a track ───────────────────────────────────
  files: (id: string, path?: string) =>
    readMachine<FileListing>(id, `/api/tracks/${id}/files${path ? `?path=${encodeURIComponent(path)}` : ""}`),
  file: (id: string, path: string) => readMachine<FileContent>(id, `/api/tracks/${id}/file?path=${encodeURIComponent(path)}`),
  diff: (id: string) => readMachine<DiffReport>(id, `/api/tracks/${id}/diff`),
  checks: (id: string) => call<ChecksReport>(`/api/tracks/${id}/checks`),
  openPull: (id: string, body: { title?: string; base?: string; body?: string; draft?: boolean }) =>
    post<PullRef & { url: string }>(`/api/tracks/${id}/pull`, body),

  execStatus: (id: string) =>
    call<{ available: boolean; why: "no_token" | "no_machine" | "no_sprite" | "unreachable" | null; cwd: string }>(
      `/api/tracks/${id}/exec`,
    ),
  exec: (id: string, command: string, cwd?: string) => post<ExecResult>(`/api/tracks/${id}/exec`, { command, cwd }),
  /** CPU, memory and disk on the box, for the machine stats pane. */
  vitals: (id: string) => call<VitalsReport>(`/api/tracks/${id}/vitals`),

  // ── working on something with somebody else ────────────────────────
  //
  // Two sets of the same five calls, one per grain of sharing. They are spelt
  // out rather than built from a `kind` parameter because the path is the only
  // thing that differs and a helper that took `"tracks" | "projects"` would
  // read as though something else might.
  //
  /** Autocomplete over everyone who has signed in here. One character is enough. */
  findPeople: (q: string) => call<Person[]>(`/api/users?q=${encodeURIComponent(q)}`),
  people: (trackId: string) => call<Person[]>(`/api/tracks/${trackId}/people`),
  invite: (trackId: string, login: string) => post<Person[]>(`/api/tracks/${trackId}/people`, { login }),
  /** The owner removing somebody, or a member removing themselves. */
  uninvite: (trackId: string, login: string) =>
    call<Person[] | undefined>(`/api/tracks/${trackId}/people/${encodeURIComponent(login)}`, { method: "DELETE" }),

  /** Whether a link is out. Never the link itself — only its hash is stored. */
  link: (trackId: string) => call<InviteLink | null>(`/api/tracks/${trackId}/link`),
  /** Mints one, replacing whatever was out. The URL is returned exactly once. */
  mintLink: (trackId: string) => post<InviteLink>(`/api/tracks/${trackId}/link`),
  revokeLink: (trackId: string) => call<null>(`/api/tracks/${trackId}/link`, { method: "DELETE" }),

  /** The same five, for the whole project: every track on it, and the ones to come. */
  projectPeople: (projectId: string) => call<Person[]>(`/api/projects/${projectId}/people`),
  inviteToProject: (projectId: string, login: string) => post<Person[]>(`/api/projects/${projectId}/people`, { login }),
  uninviteFromProject: (projectId: string, login: string) =>
    call<Person[] | undefined>(`/api/projects/${projectId}/people/${encodeURIComponent(login)}`, { method: "DELETE" }),
  projectLink: (projectId: string) => call<InviteLink | null>(`/api/projects/${projectId}/link`),
  mintProjectLink: (projectId: string) => post<InviteLink>(`/api/projects/${projectId}/link`),
  revokeProjectLink: (projectId: string) => call<null>(`/api/projects/${projectId}/link`, { method: "DELETE" }),
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
