/**
 * What ravix remembers.
 *
 * Deliberately small, and the reason is the same one paddock gives: Fountain
 * already knows most of this, and two records of one fact drift. So the rule
 * here is that **Fountain owns the truth about machines and conversations, and
 * this database owns the truth about people**.
 *
 *   - who signed in, and their GitHub installation — Fountain has no idea
 *   - which project is which — a row, because a project's name and its repo
 *     are ravix's ideas rather than Fountain's
 *   - which track is which — a row, because a `channel_id` can say the slug
 *     but not who made it, from what, or what it is called
 *   - accepted prompts awaiting delivery — work Ravix owes the caller,
 *     which must outlive the browser that submitted it
 *
 * Everything else is read live: a track's status, its turn count, whether the
 * machine is up, what is in the worktree. Those are questions with a correct
 * answer somewhere else, and caching them here is how a UI ends up confidently
 * showing a machine that died an hour ago.
 */
import type { Sql } from "./sql";
import { PreviewStore } from "./preview-store";
import { NativeExperimentStore } from "./native-experiment-store";
import { RunnerStore } from "./runner-store";
import { BrowserStore } from "./browser-store";
import type { TrackOriginInfo } from "../shared/api";

export interface UserRow {
  id: string;
  githubId: string;
  login: string;
  name: string | null;
  avatarUrl: string | null;
  /** The user's OAuth token, encrypted. Refreshed on each sign-in. */
  tokenEnc: string | null;
  createdAt: string;
  lastSeenAt: string;
}

export interface ProjectRow {
  id: string;
  userId: string;
  name: string;
  repoFullName: string | null;
  repoPrivate: number;
  defaultBranch: string | null;
  installationId: number | null;
  agentId: string;
  environmentId: string;
  vaultId: string | null;
  runtime: string;
  model: string;
  rev: number;
  instructions: string;
  createdAt: string;
  archivedAt: string | null;
}

export interface TrackRow {
  id: string;
  projectId: string;
  conversationId: string | null;
  slug: string;
  title: string;
  branch: string;
  workdir: string;
  originKind: string;
  originBase: string | null;
  originNumber: number | null;
  originTitle: string | null;
  originUrl: string | null;
  /** The project rev this track opened at. A lower one means older settings. */
  rev: number;
  openedAt: string | null;
  closedAt: string | null;
  createdAt: string;
  createdByLogin: string;
}

export interface PromptRow {
  sequence: number;
  id: string;
  trackId: string;
  userId: string;
  authorLogin: string;
  payload: string;
  createdAt: string;
  status: "queued" | "sending" | "failed" | "unconfirmed" | "sent" | "cancelled";
  error: string | null;
}

export class Db {
  readonly previews: PreviewStore;
  readonly nativeExperiments: NativeExperimentStore;
  readonly runners: RunnerStore;
  readonly browsers: BrowserStore;

  private constructor(private readonly db: Sql) {
    this.previews = new PreviewStore(db);
    this.nativeExperiments = new NativeExperimentStore(db);
    this.runners = new RunnerStore(db);
    this.browsers = new BrowserStore(db);
  }

  /** The database with its schema in place. Every statement is idempotent, so a restart is a no-op. */
  static async open(sql: Sql): Promise<Db> {
    const db = new Db(sql);
    await db.migrate();
    await db.previews.init();
    await db.nativeExperiments.init();
    await db.runners.init();
    await db.browsers.init();
    return db;
  }

  private async migrate(): Promise<void> {
    await this.db.exec(`
      CREATE TABLE IF NOT EXISTS users (
        id            TEXT PRIMARY KEY,
        github_id     TEXT NOT NULL UNIQUE,
        login         TEXT NOT NULL,
        name          TEXT,
        avatar_url    TEXT,
        token_enc     TEXT,
        created_at    TEXT NOT NULL,
        last_seen_at  TEXT NOT NULL
      );

      -- Sessions are stored as hashes, never as the token itself: a copy of
      -- this file is then not a set of live sessions.
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash  TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at  TEXT NOT NULL,
        expires_at  TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

      -- The three Fountain ids are the project. They are written once, at
      -- creation, and never updated — the sandbox is built from them, so a
      -- row that changed one would be a row pointing at a different machine.
      CREATE TABLE IF NOT EXISTS projects (
        id              TEXT PRIMARY KEY,
        user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name            TEXT NOT NULL,
        repo_full_name  TEXT,
        repo_private    INTEGER NOT NULL DEFAULT 0,
        default_branch  TEXT,
        installation_id INTEGER,
        agent_id        TEXT NOT NULL,
        environment_id  TEXT NOT NULL,
        vault_id        TEXT,
        runtime         TEXT NOT NULL,
        model           TEXT NOT NULL,
        rev             INTEGER NOT NULL DEFAULT 1,
        instructions    TEXT NOT NULL DEFAULT '',
        created_at      TEXT NOT NULL,
        archived_at     TEXT
      );
      CREATE INDEX IF NOT EXISTS projects_user ON projects(user_id, archived_at);

      CREATE TABLE IF NOT EXISTS tracks (
        id               TEXT PRIMARY KEY,
        project_id       TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        conversation_id  TEXT,
        slug             TEXT NOT NULL,
        title            TEXT NOT NULL,
        branch           TEXT NOT NULL,
        workdir          TEXT NOT NULL,
        origin_kind      TEXT NOT NULL,
        origin_base      TEXT,
        origin_number    INTEGER,
        origin_title     TEXT,
        origin_url       TEXT,
        rev              INTEGER NOT NULL DEFAULT 1,
        opened_at        TEXT,
        closed_at        TEXT,
        created_at       TEXT NOT NULL,
        created_by_login TEXT NOT NULL
      );
      -- One live track per slug per project: the slug is a directory name on a
      -- real machine, so two of them is not a naming clash, it is two tracks
      -- writing to one worktree.
      CREATE UNIQUE INDEX IF NOT EXISTS tracks_slug ON tracks(project_id, slug) WHERE closed_at IS NULL;
      CREATE INDEX IF NOT EXISTS tracks_project ON tracks(project_id, closed_at);
      CREATE INDEX IF NOT EXISTS tracks_conversation ON tracks(conversation_id);

      CREATE TABLE IF NOT EXISTS prompt_queue (
        sequence     INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        id           TEXT NOT NULL UNIQUE,
        track_id     TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        author_login TEXT NOT NULL,
        payload      TEXT NOT NULL,
        created_at   TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'queued',
        error        TEXT
      );
      CREATE INDEX IF NOT EXISTS prompt_queue_track ON prompt_queue(track_id, status, sequence);

      -- Who else is in a track.
      --
      -- The narrower of the two memberships: somebody invited to one worktree
      -- gets that worktree. They do not see the project's other tracks, cannot
      -- open one, and cannot change what is installed on the machine — the
      -- same line paddock draws around a terminal, drawn around a branch
      -- instead. project_members below is the wider one, and the two are
      -- separate tables rather than one with a nullable track_id because they
      -- answer different questions and are read in different places. They are
      -- not, however, held at once for one person on one project: the wider
      -- grant deletes the narrower ones. See addProjectMember.
      CREATE TABLE IF NOT EXISTS track_members (
        track_id    TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        invited_by  TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        PRIMARY KEY (track_id, user_id)
      );
      CREATE INDEX IF NOT EXISTS track_members_user ON track_members(user_id);

      -- An invitation to somebody who has not signed in here yet.
      --
      -- Keyed on GitHub's **numeric id**, not the login, and that is the whole
      -- reason this table can exist safely. Logins are renameable, and a login
      -- freed by a deleted account can be taken by somebody else — so an
      -- invitation matched on @ana would eventually attach to whoever held
      -- that name on the day they signed in. The numeric id is stable and
      -- never reused. The login and avatar are display only, and are
      -- allowed to be stale by the time the person arrives.
      CREATE TABLE IF NOT EXISTS track_invites (
        track_id    TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        github_id   TEXT NOT NULL,
        login       TEXT NOT NULL,
        avatar_url  TEXT,
        invited_by  TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        PRIMARY KEY (track_id, github_id)
      );
      CREATE INDEX IF NOT EXISTS track_invites_github ON track_invites(github_id);

      -- The other way in: a link.
      --
      -- One per track, by primary key, which is what makes minting a new one
      -- *the* revoke rather than a separate operation somebody has to remember
      -- to perform. Only the hash is stored: the link is the credential, and a
      -- copy of this file should not be a set of working invitations.
      CREATE TABLE IF NOT EXISTS track_links (
        track_id    TEXT PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
        token_hash  TEXT NOT NULL UNIQUE,
        created_by  TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        expires_at  TEXT NOT NULL
      );

      -- Who else is in a *project*.
      --
      -- The wider membership, and the three tables below it are the same three
      -- the track has, one level up: a row per person, a row per person who
      -- has not signed in yet, and one link. Somebody here reaches every track
      -- on the project — the ones that exist and the ones opened tomorrow —
      -- and may open tracks of their own. They still cannot reach the
      -- project's *controls*: settings, packages, secrets, the rebuild and the
      -- delete stay with the owner, because those are the machine rather than
      -- the work on it.
      CREATE TABLE IF NOT EXISTS project_members (
        project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        invited_by  TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        PRIMARY KEY (project_id, user_id)
      );
      CREATE INDEX IF NOT EXISTS project_members_user ON project_members(user_id);

      -- Keyed on GitHub's numeric id for the same reason track_invites is:
      -- a login is renameable and reusable, so an invitation matched on the
      -- name would eventually attach to whoever holds it on the day they
      -- arrive. Here that would hand a stranger the whole machine rather than
      -- one branch, so the reasoning is the same and the stakes are higher.
      CREATE TABLE IF NOT EXISTS project_invites (
        project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
        github_id   TEXT NOT NULL,
        login       TEXT NOT NULL,
        avatar_url  TEXT,
        invited_by  TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        PRIMARY KEY (project_id, github_id)
      );
      CREATE INDEX IF NOT EXISTS project_invites_github ON project_invites(github_id);

      -- One link per project, hashed, minting is the revoke — all as the
      -- track's. The TTL is shorter, and people.ts says why: this one admits
      -- somebody to every branch on the box rather than to the one you were
      -- looking at when you sent it.
      CREATE TABLE IF NOT EXISTS project_links (
        project_id  TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
        token_hash  TEXT NOT NULL UNIQUE,
        created_by  TEXT NOT NULL,
        created_at  TEXT NOT NULL,
        expires_at  TEXT NOT NULL
      );

      -- When each person last looked at each track.
      --
      -- Per (track, person) rather than per track, because a shared track is
      -- read by more than one pair of eyes and Fountain's own unread flag
      -- belongs to the one account every machine here runs on — it would mark
      -- a track read for everybody the moment anybody opened it.
      CREATE TABLE IF NOT EXISTS track_reads (
        track_id  TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        seen_at   TEXT NOT NULL,
        PRIMARY KEY (track_id, user_id)
      );

      -- Short-lived signed state for the two GitHub round trips. Rows are
      -- deleted on use and swept on age, so a replayed callback finds nothing.
      CREATE TABLE IF NOT EXISTS oauth_states (
        state       TEXT PRIMARY KEY,
        kind        TEXT NOT NULL,
        redirect    TEXT,
        created_at  TEXT NOT NULL
      );
    `);
  }

  // ── users and sessions ───────────────────────────────────────────────

  async upsertUser(input: { githubId: string; login: string; name: string | null; avatarUrl: string | null; tokenEnc: string }): Promise<UserRow> {
    const now = new Date().toISOString();
    const [existing] = await this.db.query<{ id: string }>("SELECT id FROM users WHERE github_id = $1", [input.githubId]);
    if (existing) {
      await this.db.run("UPDATE users SET login = $1, name = $2, avatar_url = $3, token_enc = $4, last_seen_at = $5 WHERE id = $6", [
        input.login,
        input.name,
        input.avatarUrl,
        input.tokenEnc,
        now,
        existing.id,
      ]);
      return (await this.user(existing.id))!;
    }
    const id = crypto.randomUUID();
    await this.db.run(
      "INSERT INTO users (id, github_id, login, name, avatar_url, token_enc, created_at, last_seen_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
      [id, input.githubId, input.login, input.name, input.avatarUrl, input.tokenEnc, now, now],
    );
    return (await this.user(id))!;
  }

  async user(id: string): Promise<UserRow | null> {
    const [r] = await this.db.query<RawUser>("SELECT * FROM users WHERE id = $1", [id]);
    return r ? toUser(r) : null;
  }

  async createSession(userId: string, tokenHash: string, maxAgeMs: number): Promise<void> {
    const now = Date.now();
    await this.db.run("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES ($1, $2, $3, $4)", [
      tokenHash,
      userId,
      new Date(now).toISOString(),
      new Date(now + maxAgeMs).toISOString(),
    ]);
  }

  async sessionUser(tokenHash: string): Promise<UserRow | null> {
    const [row] = await this.db.query<{ user_id: string; expires_at: string }>("SELECT user_id, expires_at FROM sessions WHERE token_hash = $1", [tokenHash]);
    if (!row) return null;
    if (Date.parse(row.expires_at) <= Date.now()) {
      await this.db.run("DELETE FROM sessions WHERE token_hash = $1", [tokenHash]);
      return null;
    }
    return this.user(row.user_id);
  }

  async endSession(tokenHash: string): Promise<void> {
    await this.db.run("DELETE FROM sessions WHERE token_hash = $1", [tokenHash]);
  }

  // ── the two GitHub round trips ───────────────────────────────────────

  async putState(state: string, kind: string, redirect: string | null): Promise<void> {
    await this.db.run("DELETE FROM oauth_states WHERE created_at < $1", [new Date(Date.now() - 15 * 60_000).toISOString()]);
    await this.db.run(
      `INSERT INTO oauth_states (state, kind, redirect, created_at) VALUES ($1, $2, $3, $4)
       ON CONFLICT(state) DO UPDATE SET kind = excluded.kind, redirect = excluded.redirect, created_at = excluded.created_at`,
      [state, kind, redirect, new Date().toISOString()],
    );
  }

  /** Takes the state — one use only, which is what makes a replayed callback fail. */
  async takeState(state: string): Promise<{ kind: string; redirect: string | null } | null> {
    const [row] = await this.db.query<{ kind: string; redirect: string | null; created_at: string }>(
      "DELETE FROM oauth_states WHERE state = $1 RETURNING kind, redirect, created_at",
      [state],
    );
    if (!row) return null;
    if (Date.parse(row.created_at) < Date.now() - 15 * 60_000) return null;
    return { kind: row.kind, redirect: row.redirect };
  }

  // ── projects ─────────────────────────────────────────────────────────

  async createProject(p: Omit<ProjectRow, "createdAt" | "archivedAt" | "rev">): Promise<ProjectRow> {
    const now = new Date().toISOString();
    await this.db.run(
      `INSERT INTO projects (id, user_id, name, repo_full_name, repo_private, default_branch, installation_id,
        agent_id, environment_id, vault_id, runtime, model, rev, instructions, created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 1, $13, $14)`,
      [
        p.id,
        p.userId,
        p.name,
        p.repoFullName,
        p.repoPrivate,
        p.defaultBranch,
        p.installationId,
        p.agentId,
        p.environmentId,
        p.vaultId,
        p.runtime,
        p.model,
        p.instructions,
        now,
      ],
    );
    return (await this.project(p.id))!;
  }

  async project(id: string): Promise<ProjectRow | null> {
    const [r] = await this.db.query<RawProject>("SELECT * FROM projects WHERE id = $1", [id]);
    return r ? toProject(r) : null;
  }

  async projectsOf(userId: string): Promise<ProjectRow[]> {
    const rows = await this.db.query<RawProject>("SELECT * FROM projects WHERE user_id = $1 AND archived_at IS NULL ORDER BY created_at", [userId]);
    return rows.map(toProject);
  }

  async renameProject(id: string, name: string): Promise<void> {
    await this.db.run("UPDATE projects SET name = $1 WHERE id = $2", [name, id]);
  }

  async setInstructions(id: string, instructions: string): Promise<void> {
    await this.db.run("UPDATE projects SET instructions = $1 WHERE id = $2", [instructions, id]);
  }

  async setHarness(id: string, runtime: string, model: string): Promise<void> {
    await this.db.run("UPDATE projects SET runtime = $1, model = $2 WHERE id = $3", [runtime, model, id]);
  }

  /**
   * Bump the settings revision, and return the new one.
   *
   * Called whenever something Fountain injects at session start changes — a
   * secret, an MCP server, a skill, the system prompt. Tracks already open
   * carry the old number in their `channel_id` and are badged as running older
   * settings, which is true and cannot be worked out any other way.
   */
  async bumpRev(id: string): Promise<number> {
    const [row] = await this.db.query<{ rev: number }>("UPDATE projects SET rev = rev + 1 WHERE id = $1 RETURNING rev", [id]);
    return row?.rev ?? 1;
  }

  /**
   * The one column of the three that ever moves, and only on a rebuild.
   *
   * Retiring the agent is what changes the sandbox identity; the environment
   * and vault stay, which is what makes "new machine, same settings" a real
   * distinction rather than a slower delete. Every track of the old disk is
   * closed by the caller in the same breath — a track is a worktree, and that
   * worktree is about to stop existing.
   */
  async rebindAgent(id: string, agentId: string): Promise<void> {
    await this.db.run("UPDATE projects SET agent_id = $1 WHERE id = $2", [agentId, id]);
  }

  async archiveProject(id: string): Promise<void> {
    for (const track of await this.tracksOf(id)) await this.cancelTrackPrompts(track.id);
    await this.db.run("UPDATE projects SET archived_at = $1 WHERE id = $2", [new Date().toISOString(), id]);
  }

  // ── tracks ───────────────────────────────────────────────────────────

  async createTrack(t: Omit<TrackRow, "createdAt" | "openedAt" | "closedAt">): Promise<TrackRow> {
    await this.db.run(
      `INSERT INTO tracks (id, project_id, conversation_id, slug, title, branch, workdir,
        origin_kind, origin_base, origin_number, origin_title, origin_url, rev, created_at, created_by_login)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)`,
      [
        t.id,
        t.projectId,
        t.conversationId,
        t.slug,
        t.title,
        t.branch,
        t.workdir,
        t.originKind,
        t.originBase,
        t.originNumber,
        t.originTitle,
        t.originUrl,
        t.rev,
        new Date().toISOString(),
        t.createdByLogin,
      ],
    );
    return (await this.track(t.id))!;
  }

  async track(id: string): Promise<TrackRow | null> {
    const [r] = await this.db.query<RawTrack>("SELECT * FROM tracks WHERE id = $1", [id]);
    return r ? toTrack(r) : null;
  }

  async trackByConversation(conversationId: string): Promise<TrackRow | null> {
    const [r] = await this.db.query<RawTrack>("SELECT * FROM tracks WHERE conversation_id = $1", [conversationId]);
    return r ? toTrack(r) : null;
  }

  async tracksOf(projectId: string, includeClosed = false): Promise<TrackRow[]> {
    const sql = includeClosed
      ? "SELECT * FROM tracks WHERE project_id = $1 ORDER BY created_at"
      : "SELECT * FROM tracks WHERE project_id = $1 AND closed_at IS NULL ORDER BY created_at";
    return (await this.db.query<RawTrack>(sql, [projectId])).map(toTrack);
  }

  /** Whether a slug is free right now — the unique index enforces it, this explains it. */
  async slugTaken(projectId: string, slug: string): Promise<boolean> {
    const [row] = await this.db.query<{ n: number }>(
      "SELECT COUNT(*) AS n FROM tracks WHERE project_id = $1 AND slug = $2 AND closed_at IS NULL",
      [projectId, slug],
    );
    return !!row?.n;
  }

  async attachConversation(trackId: string, conversationId: string): Promise<void> {
    await this.db.run("UPDATE tracks SET conversation_id = $1 WHERE id = $2", [conversationId, trackId]);
  }

  async markOpened(trackId: string): Promise<void> {
    await this.db.run("UPDATE tracks SET opened_at = COALESCE(opened_at, $1) WHERE id = $2", [new Date().toISOString(), trackId]);
  }

  async renameTrack(trackId: string, title: string): Promise<void> {
    await this.db.run("UPDATE tracks SET title = $1 WHERE id = $2", [title, trackId]);
  }

  async closeTrack(trackId: string): Promise<void> {
    await this.cancelTrackPrompts(trackId);
    await this.db.run("UPDATE tracks SET closed_at = $1 WHERE id = $2", [new Date().toISOString(), trackId]);
  }

  async enqueuePrompt(p: Pick<PromptRow, "id" | "trackId" | "userId" | "authorLogin" | "payload">): Promise<PromptRow> {
    await this.db.run(`INSERT INTO prompt_queue (id, track_id, user_id, author_login, payload, created_at)
      VALUES ($1, $2, $3, $4, $5, $6)`, [p.id, p.trackId, p.userId, p.authorLogin, p.payload, new Date().toISOString()]);
    return (await this.queuedPrompt(p.id))!;
  }

  async queuedPrompt(id: string): Promise<PromptRow | null> {
    const [row] = await this.db.query<PromptRow>(`SELECT ${PROMPT_COLUMNS}, payload FROM prompt_queue WHERE id = $1`, [id]);
    return row ?? null;
  }

  queuedPrompts(trackId?: string): Promise<PromptRow[]> {
    const where = "status NOT IN ('sent', 'cancelled')";
    return trackId === undefined
      ? this.db.query<PromptRow>(`SELECT ${PROMPT_COLUMNS}, payload FROM prompt_queue WHERE ${where} ORDER BY sequence`)
      : this.db.query<PromptRow>(`SELECT ${PROMPT_COLUMNS}, payload FROM prompt_queue WHERE ${where} AND track_id = $1 ORDER BY sequence`, [trackId]);
  }

  promptQueueHeads(): Promise<Omit<PromptRow, "payload">[]> {
    // Do not load every queued attachment on every sweep. Only the first live
    // row per track can be delivered; its bytes are loaded just before POST.
    return this.db.query<Omit<PromptRow, "payload">>(`SELECT ${PROMPT_COLUMNS}
      FROM prompt_queue WHERE sequence IN (
        SELECT MIN(sequence) FROM prompt_queue WHERE status NOT IN ('sent', 'cancelled') GROUP BY track_id
      ) ORDER BY sequence`);
  }

  promptQueueSummaries(trackId: string): Promise<(Omit<PromptRow, "payload"> & { prompt: string; imageCount: number })[]> {
    // A delivered or cancelled row has an emptied payload, which is not JSON;
    // those rows are filtered out, and NULLIF keeps the cast honest anyway.
    return this.db.query<Omit<PromptRow, "payload"> & { prompt: string; imageCount: number }>(`
      SELECT ${PROMPT_COLUMNS},
        NULLIF(payload, '')::jsonb->>'prompt' AS prompt,
        COALESCE(jsonb_array_length(NULLIF(payload, '')::jsonb->'images'), 0) AS "imageCount"
      FROM prompt_queue WHERE track_id = $1 AND status NOT IN ('sent', 'cancelled') ORDER BY sequence`, [trackId]);
  }

  async setPromptStatus(id: string, status: PromptRow["status"], error: string | null = null): Promise<void> {
    // Keep the id as a receipt for retried HTTP requests, release large images.
    await this.db.run("UPDATE prompt_queue SET status = $1, error = $2, payload = CASE WHEN $1 IN ('sent', 'cancelled') THEN '' ELSE payload END WHERE id = $3 AND status NOT IN ('sent', 'cancelled')", [status, error, id]);
  }

  async claimPrompt(id: string): Promise<boolean> {
    return (await this.db.run("UPDATE prompt_queue SET status = 'sending', error = NULL WHERE id = $1 AND status = 'queued'", [id])) === 1;
  }

  async recoverPromptQueue(): Promise<void> {
    await this.db.run("UPDATE prompt_queue SET status = 'unconfirmed', error = 'The server restarted during delivery. Check the transcript before sending this again.' WHERE status = 'sending'");
  }

  async cancelTrackPrompts(trackId: string): Promise<void> {
    await this.db.run("UPDATE prompt_queue SET status = 'cancelled', payload = '', error = NULL WHERE track_id = $1 AND status != 'sent'", [trackId]);
  }

  // ── who else is in a track ───────────────────────────────────────────

  async addMember(trackId: string, userId: string, invitedBy: string): Promise<void> {
    await this.db.run(
      "INSERT INTO track_members (track_id, user_id, invited_by, created_at) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
      [trackId, userId, invitedBy, new Date().toISOString()],
    );
  }

  async removeMember(trackId: string, userId: string): Promise<void> {
    await this.previews.revoke(trackId, userId);
    await this.previews.revokeAgent(trackId, userId);
    await this.browsers.revoke(trackId, userId);
    await this.db.run("DELETE FROM track_members WHERE track_id = $1 AND user_id = $2", [trackId, userId]);
  }

  async isMember(trackId: string, userId: string): Promise<boolean> {
    const [row] = await this.db.query<{ n: number }>("SELECT COUNT(*) AS n FROM track_members WHERE track_id = $1 AND user_id = $2", [trackId, userId]);
    return !!row?.n;
  }

  /** Everyone invited to a track, oldest invitation first. Excludes the owner. */
  async membersOf(trackId: string): Promise<UserRow[]> {
    const rows = await this.db.query<RawUser>(
      `SELECT u.* FROM track_members m JOIN users u ON u.id = m.user_id
       WHERE m.track_id = $1 ORDER BY m.created_at`,
      [trackId],
    );
    return rows.map(toUser);
  }

  /** The tracks this person was invited to, across every project. */
  async memberTracks(userId: string): Promise<TrackRow[]> {
    const rows = await this.db.query<RawTrack>(
      `SELECT t.* FROM track_members m JOIN tracks t ON t.id = m.track_id
       WHERE m.user_id = $1 AND t.closed_at IS NULL ORDER BY t.created_at`,
      [userId],
    );
    return rows.map(toTrack);
  }

  /**
   * Anyone whose login starts with or contains this, for the invite box.
   *
   * Deliberately the whole userbase rather than some notion of "people you
   * have worked with": the app has no such notion, and inventing one would
   * make the box quietly useless for the first invitation anybody sends. It
   * does mean the box will tell you who has signed in here, which is a trade
   * this deployment has accepted — see the note on the route.
   *
   * Ordered so a prefix match beats a contains match, because somebody typing
   * `ana` means `ana` before `joana`.
   */
  async searchUsers(q: string, excludeUserId: string, limit = 8): Promise<UserRow[]> {
    const like = `%${q}%`;
    const prefix = `${q}%`;
    const rows = await this.db.query<RawUser>(
      `SELECT * FROM users
       WHERE id != $1 AND (login ILIKE $2 OR name ILIKE $2)
       ORDER BY CASE WHEN login ILIKE $3 THEN 0 ELSE 1 END, login
       LIMIT $4`,
      [excludeUserId, like, prefix, limit],
    );
    return rows.map(toUser);
  }

  async userByLogin(login: string): Promise<UserRow | null> {
    const [r] = await this.db.query<RawUser>("SELECT * FROM users WHERE LOWER(login) = LOWER($1)", [login]);
    return r ? toUser(r) : null;
  }

  // ── invitations to somebody who is not here yet ──────────────────────

  async addInvite(input: { trackId: string; githubId: string; login: string; avatarUrl: string | null; invitedBy: string }): Promise<void> {
    await this.db.run(
      `INSERT INTO track_invites (track_id, github_id, login, avatar_url, invited_by, created_at)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT(track_id, github_id) DO UPDATE SET login = excluded.login, avatar_url = excluded.avatar_url`,
      [input.trackId, input.githubId, input.login, input.avatarUrl, input.invitedBy, new Date().toISOString()],
    );
  }

  async invitesOf(trackId: string): Promise<{ githubId: string; login: string; avatarUrl: string | null }[]> {
    const rows = await this.db.query<{ github_id: string; login: string; avatar_url: string | null }>(
      "SELECT github_id, login, avatar_url FROM track_invites WHERE track_id = $1 ORDER BY created_at",
      [trackId],
    );
    return rows.map((r) => ({ githubId: r.github_id, login: r.login, avatarUrl: r.avatar_url }));
  }

  async removeInviteByLogin(trackId: string, login: string): Promise<boolean> {
    return (await this.db.run("DELETE FROM track_invites WHERE track_id = $1 AND LOWER(login) = LOWER($2)", [trackId, login])) > 0;
  }

  /**
   * Turn every invitation waiting for this person into a membership.
   *
   * Run once, on the sign-in that creates or refreshes their account. Matching
   * is on the GitHub id the profile just came back with, so an invitation sent
   * to a login they have since changed still finds them, and one sent to a
   * login somebody *else* now holds does not.
   *
   * Returns what they just joined, so the sign-in can say so.
   *
   * Projects are claimed **first**, and a track invitation on a project they
   * have just joined outright is then dropped rather than honoured. It grants
   * nothing they do not already have, and writing it would be writing the
   * narrower row that `addProjectMember` exists to delete.
   */
  claimInvites(userId: string, githubId: string): Promise<{ tracks: TrackRow[]; projects: ProjectRow[] }> {
    return this.db.transaction(async () => {
      const pendingProjects = await this.db.query<{ project_id: string }>("SELECT project_id FROM project_invites WHERE github_id = $1", [githubId]);
      const projects: ProjectRow[] = [];
      for (const { project_id } of pendingProjects) {
        const project = await this.project(project_id);
        // An archived project is not somewhere to arrive, and neither is your
        // own: ownership is the stronger claim and is a column, not a row here.
        if (project && !project.archivedAt && project.userId !== userId) {
          await this.addProjectMember(project_id, userId, "invite");
          projects.push(project);
        }
      }
      await this.db.run("DELETE FROM project_invites WHERE github_id = $1", [githubId]);

      const pendingTracks = await this.db.query<{ track_id: string }>("SELECT track_id FROM track_invites WHERE github_id = $1", [githubId]);
      const tracks: TrackRow[] = [];
      for (const { track_id } of pendingTracks) {
        const track = await this.track(track_id);
        // A track closed while the invitation sat unclaimed is not somewhere to
        // arrive. Drop the invitation rather than granting a dead seat.
        if (!track || track.closedAt) continue;
        if (await this.isProjectMember(track.projectId, userId)) continue;
        await this.addMember(track_id, userId, "invite");
        tracks.push(track);
      }
      await this.db.run("DELETE FROM track_invites WHERE github_id = $1", [githubId]);

      return { tracks, projects };
    });
  }

  // ── the link ─────────────────────────────────────────────────────────

  async putLink(trackId: string, tokenHash: string, createdBy: string, ttlMs: number): Promise<void> {
    const now = Date.now();
    await this.db.run(
      `INSERT INTO track_links (track_id, token_hash, created_by, created_at, expires_at)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT(track_id) DO UPDATE SET
         token_hash = excluded.token_hash, created_by = excluded.created_by,
         created_at = excluded.created_at, expires_at = excluded.expires_at`,
      [trackId, tokenHash, createdBy, new Date(now).toISOString(), new Date(now + ttlMs).toISOString()],
    );
  }

  async linkOf(trackId: string): Promise<{ createdAt: string; expiresAt: string } | null> {
    const [r] = await this.db.query<{ created_at: string; expires_at: string }>(
      "SELECT created_at, expires_at FROM track_links WHERE track_id = $1",
      [trackId],
    );
    if (!r) return null;
    return { createdAt: r.created_at, expiresAt: r.expires_at };
  }

  async dropLink(trackId: string): Promise<void> {
    await this.db.run("DELETE FROM track_links WHERE track_id = $1", [trackId]);
  }

  /** The track a link opens, or null if it is unknown, revoked or expired. */
  async trackForLink(tokenHash: string): Promise<TrackRow | null> {
    const [r] = await this.db.query<{ track_id: string; expires_at: string }>(
      "SELECT track_id, expires_at FROM track_links WHERE token_hash = $1",
      [tokenHash],
    );
    if (!r) return null;
    if (Date.parse(r.expires_at) <= Date.now()) return null;
    const track = await this.track(r.track_id);
    return track && !track.closedAt ? track : null;
  }

  // ── who else is in a project ─────────────────────────────────────────

  /**
   * Somebody into the whole project, replacing whatever narrower rows they had.
   *
   * The subsumption is the point, and it is here rather than in the route so
   * that the three ways in — invited by name, arrived on a link, claimed on
   * sign-in — cannot disagree about it. **One person holds one grade of access
   * to a project.** Two rows granting the same person the same track by
   * different routes is a state nothing on screen can render honestly: the
   * people list would have to show them twice or pick one, and removing them
   * from the project would leave behind access that neither list explained.
   *
   * So this is a promotion, not an addition, and the corollary is worth saying
   * plainly because it is the surprising half: **taking somebody off a project
   * takes away every track on it**, including one they were named on
   * separately before they were promoted. The alternative — a hidden narrower
   * row that survives — is worse, because it is invisible at exactly the
   * moment somebody is trying to revoke access.
   */
  async addProjectMember(projectId: string, userId: string, invitedBy: string): Promise<void> {
    await this.db.run(
      "INSERT INTO project_members (project_id, user_id, invited_by, created_at) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
      [projectId, userId, invitedBy, new Date().toISOString()],
    );
    await this.db.run(
      "DELETE FROM track_members WHERE user_id = $1 AND track_id IN (SELECT id FROM tracks WHERE project_id = $2)",
      [userId, projectId],
    );
  }

  async removeProjectMember(projectId: string, userId: string): Promise<void> {
    const tracks = await this.tracksOf(projectId);
    for (const track of tracks) await this.previews.revoke(track.id, userId);
    for (const track of tracks) await this.previews.revokeAgent(track.id, userId);
    for (const track of tracks) await this.browsers.revoke(track.id, userId);
    await this.db.run("DELETE FROM project_members WHERE project_id = $1 AND user_id = $2", [projectId, userId]);
  }

  async isProjectMember(projectId: string, userId: string): Promise<boolean> {
    const [row] = await this.db.query<{ n: number }>("SELECT COUNT(*) AS n FROM project_members WHERE project_id = $1 AND user_id = $2", [projectId, userId]);
    return !!row?.n;
  }

  /** Everyone invited to the whole project, oldest first. Excludes the owner. */
  async projectMembersOf(projectId: string): Promise<UserRow[]> {
    const rows = await this.db.query<RawUser>(
      `SELECT u.* FROM project_members m JOIN users u ON u.id = m.user_id
       WHERE m.project_id = $1 ORDER BY m.created_at`,
      [projectId],
    );
    return rows.map(toUser);
  }

  /** The projects this person was invited into whole. Never the ones they own. */
  async memberProjects(userId: string): Promise<ProjectRow[]> {
    const rows = await this.db.query<RawProject>(
      `SELECT p.* FROM project_members m JOIN projects p ON p.id = m.project_id
       WHERE m.user_id = $1 AND p.archived_at IS NULL ORDER BY p.created_at`,
      [userId],
    );
    return rows.map(toProject);
  }

  /**
   * The same promotion, for somebody who has not arrived yet.
   *
   * A pending track invitation on this project is dropped with it, for the
   * reason the memberships are: it would grant nothing on the sign-in that
   * honoured them both, and until then it sits in the track's people list as a
   * row whose × cancels an invitation that was already superseded.
   */
  async addProjectInvite(input: { projectId: string; githubId: string; login: string; avatarUrl: string | null; invitedBy: string }): Promise<void> {
    await this.db.run(
      `INSERT INTO project_invites (project_id, github_id, login, avatar_url, invited_by, created_at)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT(project_id, github_id) DO UPDATE SET login = excluded.login, avatar_url = excluded.avatar_url`,
      [input.projectId, input.githubId, input.login, input.avatarUrl, input.invitedBy, new Date().toISOString()],
    );
    await this.db.run(
      "DELETE FROM track_invites WHERE github_id = $1 AND track_id IN (SELECT id FROM tracks WHERE project_id = $2)",
      [input.githubId, input.projectId],
    );
  }

  /** Whether an invitation to the whole project is already out for this account. */
  async hasProjectInvite(projectId: string, githubId: string): Promise<boolean> {
    const [row] = await this.db.query<{ n: number }>("SELECT COUNT(*) AS n FROM project_invites WHERE project_id = $1 AND github_id = $2", [projectId, githubId]);
    return !!row?.n;
  }

  async projectInvitesOf(projectId: string): Promise<{ githubId: string; login: string; avatarUrl: string | null }[]> {
    const rows = await this.db.query<{ github_id: string; login: string; avatar_url: string | null }>(
      "SELECT github_id, login, avatar_url FROM project_invites WHERE project_id = $1 ORDER BY created_at",
      [projectId],
    );
    return rows.map((r) => ({ githubId: r.github_id, login: r.login, avatarUrl: r.avatar_url }));
  }

  async removeProjectInviteByLogin(projectId: string, login: string): Promise<boolean> {
    return (await this.db.run("DELETE FROM project_invites WHERE project_id = $1 AND LOWER(login) = LOWER($2)", [projectId, login])) > 0;
  }

  async putProjectLink(projectId: string, tokenHash: string, createdBy: string, ttlMs: number): Promise<void> {
    const now = Date.now();
    await this.db.run(
      `INSERT INTO project_links (project_id, token_hash, created_by, created_at, expires_at)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT(project_id) DO UPDATE SET
         token_hash = excluded.token_hash, created_by = excluded.created_by,
         created_at = excluded.created_at, expires_at = excluded.expires_at`,
      [projectId, tokenHash, createdBy, new Date(now).toISOString(), new Date(now + ttlMs).toISOString()],
    );
  }

  async projectLinkOf(projectId: string): Promise<{ createdAt: string; expiresAt: string } | null> {
    const [r] = await this.db.query<{ created_at: string; expires_at: string }>(
      "SELECT created_at, expires_at FROM project_links WHERE project_id = $1",
      [projectId],
    );
    if (!r) return null;
    return { createdAt: r.created_at, expiresAt: r.expires_at };
  }

  async dropProjectLink(projectId: string): Promise<void> {
    await this.db.run("DELETE FROM project_links WHERE project_id = $1", [projectId]);
  }

  /** The project a link opens, or null if it is unknown, revoked, expired or archived. */
  async projectForLink(tokenHash: string): Promise<ProjectRow | null> {
    const [r] = await this.db.query<{ project_id: string; expires_at: string }>(
      "SELECT project_id, expires_at FROM project_links WHERE token_hash = $1",
      [tokenHash],
    );
    if (!r) return null;
    if (Date.parse(r.expires_at) <= Date.now()) return null;
    const project = await this.project(r.project_id);
    return project && !project.archivedAt ? project : null;
  }

  // ── what you have not read ───────────────────────────────────────────

  async markRead(trackId: string, userId: string, at = new Date().toISOString()): Promise<void> {
    await this.db.run(
      `INSERT INTO track_reads (track_id, user_id, seen_at) VALUES ($1, $2, $3)
       ON CONFLICT(track_id, user_id) DO UPDATE SET seen_at = excluded.seen_at`,
      [trackId, userId, at],
    );
  }

  /** When this person last looked at each of a project's tracks. */
  async readsOf(userId: string, projectId: string): Promise<Map<string, string>> {
    const rows = await this.db.query<{ track_id: string; seen_at: string }>(
      `SELECT r.track_id, r.seen_at FROM track_reads r JOIN tracks t ON t.id = r.track_id
       WHERE r.user_id = $1 AND t.project_id = $2`,
      [userId, projectId],
    );
    return new Map(rows.map((r) => [r.track_id, r.seen_at]));
  }

  async lastReadOf(trackId: string, userId: string): Promise<string | null> {
    const [row] = await this.db.query<{ seen_at: string }>("SELECT seen_at FROM track_reads WHERE track_id = $1 AND user_id = $2", [trackId, userId]);
    return row?.seen_at ?? null;
  }

  /** One serialised transaction over everything above; see `sql.ts`. */
  transaction<T>(fn: () => Promise<T>): Promise<T> {
    return this.db.transaction(fn);
  }

  close(): Promise<void> {
    return this.db.close();
  }
}

/** The queue's columns as `PromptRow` spells them. */
const PROMPT_COLUMNS = `sequence, id, track_id AS "trackId", user_id AS "userId", author_login AS "authorLogin", created_at AS "createdAt", status, error`;

// ── row shapes, and the snake_case border ──────────────────────────────

interface RawUser {
  id: string;
  github_id: string;
  login: string;
  name: string | null;
  avatar_url: string | null;
  token_enc: string | null;
  created_at: string;
  last_seen_at: string;
}

interface RawProject {
  id: string;
  user_id: string;
  name: string;
  repo_full_name: string | null;
  repo_private: number;
  default_branch: string | null;
  installation_id: number | null;
  agent_id: string;
  environment_id: string;
  vault_id: string | null;
  runtime: string;
  model: string;
  rev: number;
  instructions: string;
  created_at: string;
  archived_at: string | null;
}

interface RawTrack {
  id: string;
  project_id: string;
  conversation_id: string | null;
  slug: string;
  title: string;
  branch: string;
  workdir: string;
  origin_kind: string;
  origin_base: string | null;
  origin_number: number | null;
  origin_title: string | null;
  origin_url: string | null;
  rev: number;
  opened_at: string | null;
  closed_at: string | null;
  created_at: string;
  created_by_login: string;
}

function toUser(r: RawUser): UserRow {
  return {
    id: r.id,
    githubId: r.github_id,
    login: r.login,
    name: r.name,
    avatarUrl: r.avatar_url,
    tokenEnc: r.token_enc,
    createdAt: r.created_at,
    lastSeenAt: r.last_seen_at,
  };
}

function toProject(r: RawProject): ProjectRow {
  return {
    id: r.id,
    userId: r.user_id,
    name: r.name,
    repoFullName: r.repo_full_name,
    repoPrivate: r.repo_private,
    defaultBranch: r.default_branch,
    installationId: r.installation_id,
    agentId: r.agent_id,
    environmentId: r.environment_id,
    vaultId: r.vault_id,
    runtime: r.runtime,
    model: r.model,
    rev: r.rev,
    instructions: r.instructions,
    createdAt: r.created_at,
    archivedAt: r.archived_at,
  };
}

function toTrack(r: RawTrack): TrackRow {
  return {
    id: r.id,
    projectId: r.project_id,
    conversationId: r.conversation_id,
    slug: r.slug,
    title: r.title,
    branch: r.branch,
    workdir: r.workdir,
    originKind: r.origin_kind,
    originBase: r.origin_base,
    originNumber: r.origin_number,
    originTitle: r.origin_title,
    originUrl: r.origin_url,
    rev: r.rev,
    openedAt: r.opened_at,
    closedAt: r.closed_at,
    createdAt: r.created_at,
    createdByLogin: r.created_by_login,
  };
}

/** The origin as the API serves it, from the four columns it lives in. */
export function originOf(t: TrackRow): TrackOriginInfo {
  return {
    kind: (t.originKind as TrackOriginInfo["kind"]) ?? "blank",
    base: t.originBase,
    number: t.originNumber,
    title: t.originTitle,
    url: t.originUrl,
  };
}
