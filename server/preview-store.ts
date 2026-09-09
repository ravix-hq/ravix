import type { Sql } from "./sql";
import type { PreviewConfig, PreviewState } from "../shared/previews";

export interface PreviewRow {
  trackId: string;
  hostname: string;
  config: PreviewConfig | null;
  appliedConfig: string | null;
  sandboxId: string | null;
  sprite: string | null;
  port: number | null;
  service: string;
  desired: "running" | "stopped";
  state: PreviewState;
  generation: number;
  lastActivity: number;
  leaseUntil: number;
  startedAt: number;
  error: string | null;
  logs: string;
  cleanup: boolean;
  stopPending: boolean;
  unavailable?: string | null;
}
export interface PreviewGrant {
  hash: string;
  trackId: string;
  sessionHash: string;
  expires: number;
  kind: "ticket" | "session";
}
export interface AgentPreviewGrant {
  hash: string; trackId: string; userId: string; conversationId: string; promptId: string;
  sandboxId: string; sprite: string; expires: number;
}

/** Additive tables; the unique index owns allocation, including across connections. */
export class PreviewStore {
  constructor(private db: Sql) {}
  async init() {
    await this.db.exec(`
      CREATE TABLE IF NOT EXISTS preview_defaults (
        project_id TEXT PRIMARY KEY REFERENCES projects(id), config TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS previews (
        track_id TEXT PRIMARY KEY REFERENCES tracks(id), hostname TEXT NOT NULL UNIQUE,
        sprite TEXT, port INTEGER, row TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS preview_ports ON previews(sprite, port) WHERE sprite IS NOT NULL;
      CREATE TABLE IF NOT EXISTS preview_grants (
        hash TEXT PRIMARY KEY, track_id TEXT NOT NULL REFERENCES tracks(id),
        session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
        expires BIGINT NOT NULL, kind TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS preview_agent_grants (
        hash TEXT PRIMARY KEY, track_id TEXT NOT NULL UNIQUE REFERENCES tracks(id),
        user_id TEXT NOT NULL REFERENCES users(id), expires BIGINT NOT NULL, row TEXT NOT NULL
      );
    `);
  }
  async defaults(projectId: string): Promise<PreviewConfig | null> {
    const [row] = await this.db.query<{ config: string }>("SELECT config FROM preview_defaults WHERE project_id=$1", [projectId]);
    return row ? JSON.parse(row.config) : null;
  }
  async setDefaults(projectId: string, config: PreviewConfig | null) {
    if (!config) await this.db.run("DELETE FROM preview_defaults WHERE project_id=$1", [projectId]);
    else await this.db.run("INSERT INTO preview_defaults VALUES ($1,$2) ON CONFLICT(project_id) DO UPDATE SET config=excluded.config", [projectId, JSON.stringify(config)]);
  }
  async get(trackId: string): Promise<PreviewRow | null> {
    const [r] = await this.db.query<{ row: string }>("SELECT row FROM previews WHERE track_id=$1", [trackId]);
    return r ? JSON.parse(r.row) : null;
  }
  async byHost(hostname: string): Promise<PreviewRow | null> {
    const [r] = await this.db.query<{ row: string }>("SELECT row FROM previews WHERE hostname=$1", [hostname]);
    return r ? JSON.parse(r.row) : null;
  }
  async all(): Promise<PreviewRow[]> {
    return (await this.db.query<{ row: string }>("SELECT row FROM previews")).map(r => JSON.parse(r.row));
  }
  async ensure(trackId: string): Promise<PreviewRow> {
    const old = await this.get(trackId);
    if (old) return old;
    const host = `t-${crypto.randomUUID().replaceAll("-", "")}`;
    const row: PreviewRow = { trackId, hostname: host, config: null, appliedConfig: null, sandboxId: null, sprite: null,
      port: null, service: `sy-${host}`, desired: "stopped", state: "stopped", generation: 0, lastActivity: 0,
      leaseUntil: 0, startedAt: 0, error: null, logs: "", cleanup: false, stopPending: false };
    await this.save(row);
    return row;
  }
  async save(row: PreviewRow) {
    await this.db.run(`INSERT INTO previews VALUES ($1,$2,$3,$4,$5) ON CONFLICT(track_id) DO UPDATE SET
      sprite=excluded.sprite, port=excluded.port, row=excluded.row`,
    [row.trackId, row.hostname, row.sprite, row.port, JSON.stringify(row)]);
  }
  allocate(trackId: string, sandboxId: string, sprite: string): Promise<PreviewRow> {
    return this.db.transaction(async () => {
      const row = await this.ensure(trackId);
      if (row.sprite === sprite && row.port) return row;
      const used = new Set((await this.db.query<{ port: number }>("SELECT port FROM previews WHERE sprite=$1", [sprite])).map(r => r.port));
      let port = 20_000;
      while (used.has(port) && port < 30_000) port++;
      if (port === 30_000) throw new Error("This machine has no available preview ports.");
      Object.assign(row, { sprite, sandboxId, port, appliedConfig: null });
      await this.save(row);
      return row;
    });
  }
  async grant(grant: PreviewGrant) {
    await this.db.run("DELETE FROM preview_grants WHERE expires <= $1", [Date.now()]);
    await this.db.run("INSERT INTO preview_grants VALUES ($1,$2,$3,$4,$5)", [grant.hash, grant.trackId, grant.sessionHash, grant.expires, grant.kind]);
  }
  async getGrant(hash: string, trackId: string, kind: PreviewGrant["kind"], consume = false): Promise<PreviewGrant | null> {
    const query = consume
      ? "DELETE FROM preview_grants WHERE hash=$1 AND track_id=$2 AND kind=$3 AND expires>$4 RETURNING *"
      : "SELECT * FROM preview_grants WHERE hash=$1 AND track_id=$2 AND kind=$3 AND expires>$4";
    const [r] = await this.db.query<{ hash: string; track_id: string; session_hash: string; expires: number; kind: PreviewGrant["kind"] }>(query, [hash, trackId, kind, Date.now()]);
    return r ? { hash: r.hash, trackId: r.track_id, sessionHash: r.session_hash, expires: r.expires, kind: r.kind } : null;
  }
  async revoke(trackId: string, userId?: string) {
    await this.db.run(`DELETE FROM preview_grants WHERE track_id=$1${userId ? " AND session_hash IN (SELECT token_hash FROM sessions WHERE user_id=$2)" : ""}`, userId ? [trackId, userId] : [trackId]);
  }
  async grantAgent(grant: AgentPreviewGrant) {
    await this.db.run("DELETE FROM preview_agent_grants WHERE expires<=$1 OR track_id=$2", [Date.now(), grant.trackId]);
    await this.db.run("INSERT INTO preview_agent_grants VALUES ($1,$2,$3,$4,$5)", [grant.hash, grant.trackId, grant.userId, grant.expires, JSON.stringify(grant)]);
  }
  async agentGrant(hash: string): Promise<AgentPreviewGrant | null> {
    const [r] = await this.db.query<{ row: string }>("SELECT row FROM preview_agent_grants WHERE hash=$1 AND expires>$2", [hash, Date.now()]);
    return r ? JSON.parse(r.row) : null;
  }
  async revokeAgent(trackId: string, userId?: string) {
    await this.db.run(`DELETE FROM preview_agent_grants WHERE track_id=$1${userId ? " AND user_id=$2" : ""}`, userId ? [trackId, userId] : [trackId]);
  }
}
