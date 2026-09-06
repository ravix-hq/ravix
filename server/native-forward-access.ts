import type { Duplex } from "node:stream";
import type { AppContext } from "./context";
import { trackAccess } from "./context";
import { randomToken, sha256 } from "./crypto";
import { subscribe } from "./hub";
import type { NativeForwardAssignment } from "./native-forward-gateway";
import { spriteTunnel } from "./sprites-tunnel";

export type NativeServiceName = "metro" | "backend";
interface Destination { sprite: string; port: number; service: string }

/** Only the server's assignment/service manager supplies these records. This
 * is not an HTTP input schema or permission to forward a caller-selected port.
 * The manager must invalidate records when the workspace or service changes. */
export interface NativeForwardState {
  sessionId: string;
  trackId: string;
  projectId: string;
  projectRevision: number;
  runnerId: string;
  runnerOwnerId: string;
  runnerEpoch: number;
  generation: number;
  enabledProjects: readonly string[];
  leaseUntil: number;
  active: boolean;
  services: Partial<Record<NativeServiceName, Destination>>;
}

/** Supplied by authenticated control dispatch, never from a browser body. */
interface Principal {
  userId: string;
  sessionHash: string;
  runnerId: string;
  runnerEpoch: number;
}
interface Grant {
  state: NativeForwardState;
  principal: Principal;
  identity: string;
  workspace: string;
  expiresAt: number;
  controller: AbortController;
  unsubscribe: () => void;
  timer: ReturnType<typeof setTimeout>;
}

/** In-memory, short-lived experiment grants. No grant issuance route is mounted
 * until pairing and managed service assignments can supply the trusted inputs.
 * A restart drops every grant. Only verifiers are retained; returned tokens
 * must be delivered on the runner control connection, never in browser JSON. */
export class NativeForwardAccess {
  private readonly grants = new Map<string, Grant>();
  private readonly timer: ReturnType<typeof setInterval>;
  private stopped = false;

  constructor(
    private readonly ctx: AppContext,
    private readonly current: (sessionId: string) => NativeForwardState | null,
    private readonly connect: (destination: Destination, signal: AbortSignal) => Promise<Duplex> = (destination, signal) => {
      if (!ctx.config.sprites) throw new Error("Sprites transport unavailable.");
      return spriteTunnel(ctx.config.sprites, destination.sprite, destination.port, signal);
    },
  ) {
    // Includes sign-out and runner fencing, which need not publish a hub event.
    this.timer = setInterval(() => this.sweep(), 1_000);
    this.timer.unref();
  }

  async issue(sessionId: string, principal: Principal) {
    this.sweep();
    if (this.stopped || this.grants.size >= 64) throw new Error("Native forwarding unavailable.");
    const state = this.current(sessionId);
    if (!state || state.sessionId !== sessionId || !this.allowed(state, principal)) throw new Error("Native assignment unavailable.");
    const snapshot = structuredClone(state);
    const token = randomToken();
    const verifier = await sha256(token);
    // Recheck after hashing: a concurrent sign-out or revocation wins issuance.
    const current = this.current(sessionId);
    if (this.stopped || this.grants.size >= 64 || !current || identity(current) !== identity(snapshot) || !this.allowed(current, principal)) throw new Error("Native assignment ended.");
    const expiresAt = Math.min(Date.now() + 60_000, current.leaseUntil);
    const grant: Grant = {
      state: snapshot, principal: { ...principal }, identity: identity(snapshot),
      workspace: this.workspace(state.trackId), expiresAt,
      controller: new AbortController(), unsubscribe: () => {},
      timer: setTimeout(() => this.revoke(verifier), Math.max(1, expiresAt - Date.now())),
    };
    grant.timer.unref();
    this.grants.set(verifier, grant);
    grant.unsubscribe = subscribe(state.projectId, principal.userId, () => { this.live(verifier); });
    return {
      token, expiresAt,
      paths: Object.fromEntries(Object.keys(snapshot.services).map(name => [name, `/api/native/sessions/${sessionId}/forward/${name}`])) as Partial<Record<NativeServiceName, string>>,
    };
  }

  authorize = async (request: Request): Promise<NativeForwardAssignment | null> => {
    const url = new URL(request.url);
    const path = /^\/api\/native\/sessions\/([a-zA-Z0-9_-]{1,128})\/forward\/(metro|backend)$/.exec(url.pathname);
    const token = /^Bearer ([a-zA-Z0-9_-]{32,256})$/.exec(request.headers.get("authorization") ?? "")?.[1];
    if (request.method !== "GET" || request.headers.has("origin") || url.search || !path || !token) return null;
    const verifier = await sha256(token);
    const grant = this.live(verifier);
    const name = path[2] as NativeServiceName;
    if (!grant || grant.state.sessionId !== path[1]) return null;
    const destination = grant.state.services[name];
    if (!destination) return null;
    return {
      signal: grant.controller.signal,
      connect: async () => {
        if (!this.live(verifier)) throw new Error("Native assignment ended.");
        const stream = await this.connect({ ...destination }, grant.controller.signal);
        if (!this.live(verifier)) { stream.destroy(); throw new Error("Native assignment ended."); }
        return stream;
      },
    };
  };

  revokeSession(sessionId: string) {
    for (const [verifier, grant] of this.grants) if (grant.state.sessionId === sessionId) this.revoke(verifier);
  }

  stop() {
    this.stopped = true;
    clearInterval(this.timer);
    for (const verifier of this.grants.keys()) this.revoke(verifier);
  }

  private sweep() { for (const verifier of this.grants.keys()) this.live(verifier); }

  private live(verifier: string): Grant | null {
    const grant = this.grants.get(verifier);
    if (!grant) return null;
    try {
      const current = this.current(grant.state.sessionId);
      if (!this.stopped && grant.expiresAt > Date.now() && current && identity(current) === grant.identity &&
          this.allowed(current, grant.principal) && this.workspace(current.trackId) === grant.workspace) return grant;
    } catch { /* A failed state lookup cannot preserve access. */ }
    this.revoke(verifier);
    return null;
  }

  private revoke(verifier: string) {
    const grant = this.grants.get(verifier);
    if (!grant) return;
    this.grants.delete(verifier);
    clearTimeout(grant.timer); grant.unsubscribe();
    grant.controller.abort(new Error("Native assignment ended."));
  }

  private allowed(state: NativeForwardState, principal: Principal): boolean {
    try {
      if (!state.active || !Number.isFinite(state.leaseUntil) || state.leaseUntil <= Date.now() ||
          !/^[a-zA-Z0-9_-]{1,128}$/.test(state.sessionId) ||
          !Number.isSafeInteger(state.generation) || state.generation < 1 ||
          !Number.isSafeInteger(state.runnerEpoch) || state.runnerEpoch < 1 ||
          state.runnerId !== principal.runnerId || state.runnerEpoch !== principal.runnerEpoch) return false;
      const user = this.ctx.db.sessionUser(principal.sessionHash);
      if (!user || user.id !== principal.userId) return false;
      const { track, project } = trackAccess(this.ctx, user, state.trackId);
      if (track.closedAt || project.id !== state.projectId || project.rev !== state.projectRevision ||
          project.userId !== state.runnerOwnerId || !state.enabledProjects.includes(project.id)) return false;
      const services = Object.entries(state.services);
      return services.length > 0 && services.length <= 2 && services.every(([name, d]) =>
        (name === "metro" || name === "backend") && d && typeof d.sprite === "string" && d.sprite.length > 0 &&
        typeof d.service === "string" && d.service.length > 0 && Number.isInteger(d.port) && d.port >= 1024 && d.port <= 65535);
    } catch { return false; }
  }

  private workspace(trackId: string): string {
    const track = this.ctx.db.track(trackId)!;
    const project = this.ctx.db.project(track.projectId)!;
    return JSON.stringify([project.agentId, track.rev, track.workdir, track.branch, track.conversationId]);
  }
}

function identity(state: NativeForwardState): string {
  return JSON.stringify([state.sessionId, state.trackId, state.projectId, state.projectRevision,
    state.runnerId, state.runnerOwnerId, state.runnerEpoch, state.generation,
    ...(["metro", "backend"] as const).map(name => {
      const d = state.services[name];
      return d ? [d.sprite, d.port, d.service] : null;
    })]);
}
