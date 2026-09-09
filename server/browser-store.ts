import type { Sql } from "./sql";
import type { BrowserCheckpoint } from "../shared/browser";

export interface BrowserSessionRow {
  id: string; projectId: string; profile: "shared";
  sprite: string | null; sandboxId: string | null;
  state: "stopped" | "ready" | "failed"; error: string | null;
  tokenEnc: string;
}
export interface BrowserGrant {
  hash: string; trackId: string; userId: string; promptId: string;
  conversationId: string; expires: number;
  sandboxId: string; sprite: string;
}
export class BrowserStore {
  constructor(private db: Sql) {}
  async init() {
    await this.db.exec(`CREATE TABLE IF NOT EXISTS browser_sessions (
      id TEXT PRIMARY KEY, project_id TEXT NOT NULL UNIQUE REFERENCES projects(id), data TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS browser_checkpoints (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES browser_sessions(id),
      owner_id TEXT NOT NULL REFERENCES users(id), label TEXT NOT NULL, created_at TEXT NOT NULL, payload_enc TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS browser_agent_grants (
      hash TEXT PRIMARY KEY, track_id TEXT NOT NULL REFERENCES tracks(id), data TEXT NOT NULL
    );`);
  }
  async get(projectId: string): Promise<BrowserSessionRow | null> {
    const [row] = await this.db.query<{ data: string }>("SELECT data FROM browser_sessions WHERE project_id=$1", [projectId]);
    return row ? JSON.parse(row.data) : null;
  }
  async save(row: BrowserSessionRow) {
    await this.db.run("INSERT INTO browser_sessions VALUES ($1,$2,$3) ON CONFLICT(project_id) DO UPDATE SET data=excluded.data", [row.id, row.projectId, JSON.stringify(row)]);
  }
  checkpoints(sessionId: string): Promise<BrowserCheckpoint[]> {
    return this.db.query<BrowserCheckpoint>(`SELECT id, session_id AS "sessionId", label, created_at AS "createdAt" FROM browser_checkpoints WHERE session_id=$1 ORDER BY created_at DESC`, [sessionId]);
  }
  async checkpoint(id: string) {
    const [row] = await this.db.query<BrowserCheckpoint & { ownerId: string; payloadEnc: string }>(`SELECT id, session_id AS "sessionId", owner_id AS "ownerId", label, created_at AS "createdAt", payload_enc AS "payloadEnc" FROM browser_checkpoints WHERE id=$1`, [id]);
    return row ?? null;
  }
  async addCheckpoint(cp: BrowserCheckpoint, ownerId: string, payloadEnc: string) {
    await this.db.run("INSERT INTO browser_checkpoints VALUES ($1,$2,$3,$4,$5,$6)", [cp.id, cp.sessionId, ownerId, cp.label, cp.createdAt, payloadEnc]);
  }
  async deleteCheckpoint(id: string) { await this.db.run("DELETE FROM browser_checkpoints WHERE id=$1", [id]); }
  async grant(value: BrowserGrant) {
    await this.db.run("DELETE FROM browser_agent_grants WHERE track_id=$1", [value.trackId]);
    await this.db.run("INSERT INTO browser_agent_grants VALUES ($1,$2,$3)", [value.hash, value.trackId, JSON.stringify(value)]);
  }
  async agent(hash: string): Promise<BrowserGrant | null> {
    const [row] = await this.db.query<{ data: string }>("SELECT data FROM browser_agent_grants WHERE hash=$1", [hash]);
    const value: BrowserGrant | null = row ? JSON.parse(row.data) : null;
    return value && value.expires > Date.now() ? value : null;
  }
  async revoke(trackId: string, userId?: string) {
    if (!userId) await this.db.run("DELETE FROM browser_agent_grants WHERE track_id=$1", [trackId]);
    else await this.db.run("DELETE FROM browser_agent_grants WHERE track_id=$1 AND data::jsonb->>'userId'=$2", [trackId, userId]);
  }
}
