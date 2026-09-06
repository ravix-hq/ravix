import type { Database } from "bun:sqlite";
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
  constructor(private db: Database) {
    db.exec(`CREATE TABLE IF NOT EXISTS browser_sessions (
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
  get(projectId: string): BrowserSessionRow | null {
    const row = this.db.query<{ data: string }, [string]>("SELECT data FROM browser_sessions WHERE project_id=?").get(projectId);
    return row ? JSON.parse(row.data) : null;
  }
  save(row: BrowserSessionRow) {
    this.db.run("INSERT INTO browser_sessions VALUES (?,?,?) ON CONFLICT(project_id) DO UPDATE SET data=excluded.data", [row.id, row.projectId, JSON.stringify(row)]);
  }
  checkpoints(sessionId: string): BrowserCheckpoint[] {
    return this.db.query<BrowserCheckpoint, [string]>("SELECT id,session_id AS sessionId,label,created_at AS createdAt FROM browser_checkpoints WHERE session_id=? ORDER BY created_at DESC").all(sessionId);
  }
  checkpoint(id: string) {
    return this.db.query<BrowserCheckpoint & { ownerId: string; payloadEnc: string }, [string]>("SELECT id,session_id AS sessionId,owner_id AS ownerId,label,created_at AS createdAt,payload_enc AS payloadEnc FROM browser_checkpoints WHERE id=?").get(id);
  }
  addCheckpoint(cp: BrowserCheckpoint, ownerId: string, payloadEnc: string) {
    this.db.run("INSERT INTO browser_checkpoints VALUES (?,?,?,?,?,?)", [cp.id, cp.sessionId, ownerId, cp.label, cp.createdAt, payloadEnc]);
  }
  deleteCheckpoint(id: string) { this.db.run("DELETE FROM browser_checkpoints WHERE id=?", [id]); }
  grant(value: BrowserGrant) {
    this.db.run("DELETE FROM browser_agent_grants WHERE track_id=?", [value.trackId]);
    this.db.run("INSERT INTO browser_agent_grants VALUES (?,?,?)", [value.hash, value.trackId, JSON.stringify(value)]);
  }
  agent(hash: string): BrowserGrant | null {
    const row = this.db.query<{ data: string }, [string]>("SELECT data FROM browser_agent_grants WHERE hash=?").get(hash);
    const value: BrowserGrant | null = row ? JSON.parse(row.data) : null;
    return value && value.expires > Date.now() ? value : null;
  }
  revoke(trackId: string, userId?: string) {
    if (!userId) this.db.run("DELETE FROM browser_agent_grants WHERE track_id=?", [trackId]);
    else this.db.run("DELETE FROM browser_agent_grants WHERE track_id=? AND json_extract(data,'$.userId')=?", [trackId, userId]);
  }
}
