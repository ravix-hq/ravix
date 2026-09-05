import type { Database } from "bun:sqlite";
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

/** Additive tables; the unique index owns allocation, including across connections. */
export class PreviewStore {
  constructor(private db: Database) {
    db.exec(`
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
        expires INTEGER NOT NULL, kind TEXT NOT NULL
      );
    `);
  }
  defaults(projectId: string): PreviewConfig | null {
    const row = this.db.query<{ config: string }, [string]>("SELECT config FROM preview_defaults WHERE project_id=?").get(projectId);
    return row ? JSON.parse(row.config) : null;
  }
  setDefaults(projectId: string, config: PreviewConfig | null) {
    if (!config) this.db.run("DELETE FROM preview_defaults WHERE project_id=?", [projectId]);
    else this.db.run("INSERT INTO preview_defaults VALUES (?,?) ON CONFLICT(project_id) DO UPDATE SET config=excluded.config", [projectId, JSON.stringify(config)]);
  }
  get(trackId: string): PreviewRow | null {
    const r = this.db.query<{ row: string }, [string]>("SELECT row FROM previews WHERE track_id=?").get(trackId);
    return r ? JSON.parse(r.row) : null;
  }
  byHost(hostname: string): PreviewRow | null {
    const r = this.db.query<{ row: string }, [string]>("SELECT row FROM previews WHERE hostname=?").get(hostname);
    return r ? JSON.parse(r.row) : null;
  }
  all(): PreviewRow[] {
    return this.db.query<{ row: string }, []>("SELECT row FROM previews").all().map(r => JSON.parse(r.row));
  }
  ensure(trackId: string): PreviewRow {
    const old = this.get(trackId);
    if (old) return old;
    const host = `t-${crypto.randomUUID().replaceAll("-", "")}`;
    const row: PreviewRow = { trackId, hostname: host, config: null, appliedConfig: null, sandboxId: null, sprite: null,
      port: null, service: `sy-${host}`, desired: "stopped", state: "stopped", generation: 0, lastActivity: 0,
      leaseUntil: 0, startedAt: 0, error: null, logs: "", cleanup: false, stopPending: false };
    this.save(row);
    return row;
  }
  save(row: PreviewRow) {
    this.db.run(`INSERT INTO previews VALUES (?,?,?,?,?) ON CONFLICT(track_id) DO UPDATE SET
      sprite=excluded.sprite, port=excluded.port, row=excluded.row`,
    [row.trackId, row.hostname, row.sprite, row.port, JSON.stringify(row)]);
  }
  allocate(trackId: string, sandboxId: string, sprite: string): PreviewRow {
    return this.db.transaction(() => {
      const row = this.ensure(trackId);
      if (row.sprite === sprite && row.port) return row;
      const used = new Set(this.db.query<{ port: number }, [string]>("SELECT port FROM previews WHERE sprite=?").all(sprite).map(r => r.port));
      let port = 20_000;
      while (used.has(port) && port < 30_000) port++;
      if (port === 30_000) throw new Error("This machine has no available preview ports.");
      Object.assign(row, { sprite, sandboxId, port, appliedConfig: null });
      this.save(row);
      return row;
    }).immediate();
  }
  grant(grant: PreviewGrant) {
    this.db.run("DELETE FROM preview_grants WHERE expires <= ?", [Date.now()]);
    this.db.run("INSERT INTO preview_grants VALUES (?,?,?,?,?)", [grant.hash, grant.trackId, grant.sessionHash, grant.expires, grant.kind]);
  }
  getGrant(hash: string, trackId: string, kind: PreviewGrant["kind"], consume = false): PreviewGrant | null {
    const query = consume
      ? "DELETE FROM preview_grants WHERE hash=? AND track_id=? AND kind=? AND expires>? RETURNING *"
      : "SELECT * FROM preview_grants WHERE hash=? AND track_id=? AND kind=? AND expires>?";
    const r = this.db.query<{ hash: string; track_id: string; session_hash: string; expires: number; kind: PreviewGrant["kind"] }, [string, string, string, number]>(query).get(hash, trackId, kind, Date.now());
    return r ? { hash: r.hash, trackId: r.track_id, sessionHash: r.session_hash, expires: r.expires, kind: r.kind } : null;
  }
  revoke(trackId: string, userId?: string) {
    this.db.run(`DELETE FROM preview_grants WHERE track_id=?${userId ? " AND session_hash IN (SELECT token_hash FROM sessions WHERE user_id=?)" : ""}`, userId ? [trackId, userId] : [trackId]);
  }
}
