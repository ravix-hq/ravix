/**
 * What switchyard remembers.
 *
 * Deliberately small, and the reason is the same one paddock gives: Fountain
 * already knows most of this, and two records of one fact drift. So the rule
 * here is that **Fountain owns the truth about machines and conversations, and
 * this database owns the truth about people**.
 *
 *   - who signed in, and their GitHub installation — Fountain has no idea
 *   - which project is which — a row, because a project's name and its repo
 *     are switchyard's ideas rather than Fountain's
 *   - which track is which — a row, because a `channel_id` can say the slug
 *     but not who made it, from what, or what it is called
 *
 * Everything else is read live: a track's status, its turn count, whether the
 * machine is up, what is in the worktree. Those are questions with a correct
 * answer somewhere else, and caching them here is how a UI ends up confidently
 * showing a machine that died an hour ago.
 */
import { Database } from "bun:sqlite";
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

export class Db {
  private readonly db: Database;

  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.exec("PRAGMA journal_mode = WAL");
    this.db.exec("PRAGMA foreign_keys = ON");
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
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

      -- Who else is in a track.
      --
      -- Membership is per *track*, not per project, and that is the whole
      -- permission model: somebody invited to one worktree gets that worktree.
      -- They do not see the project's other tracks, cannot open one, and
      -- cannot change what is installed on the machine — the same line paddock
      -- draws around a terminal, drawn around a branch instead.
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

  upsertUser(input: { githubId: string; login: string; name: string | null; avatarUrl: string | null; tokenEnc: string }): UserRow {
    const now = new Date().toISOString();
    const existing = this.db
      .query<{ id: string }, [string]>("SELECT id FROM users WHERE github_id = ?")
      .get(input.githubId);
    if (existing) {
      this.db.run("UPDATE users SET login = ?, name = ?, avatar_url = ?, token_enc = ?, last_seen_at = ? WHERE id = ?", [
        input.login,
        input.name,
        input.avatarUrl,
        input.tokenEnc,
        now,
        existing.id,
      ]);
      return this.user(existing.id)!;
    }
    const id = crypto.randomUUID();
    this.db.run(
      "INSERT INTO users (id, github_id, login, name, avatar_url, token_enc, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [id, input.githubId, input.login, input.name, input.avatarUrl, input.tokenEnc, now, now],
    );
    return this.user(id)!;
  }

  user(id: string): UserRow | null {
    const r = this.db.query<RawUser, [string]>("SELECT * FROM users WHERE id = ?").get(id);
    return r ? toUser(r) : null;
  }

  createSession(userId: string, tokenHash: string, maxAgeMs: number): void {
    const now = Date.now();
    this.db.run("INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)", [
      tokenHash,
      userId,
      new Date(now).toISOString(),
      new Date(now + maxAgeMs).toISOString(),
    ]);
  }

  sessionUser(tokenHash: string): UserRow | null {
    const row = this.db
      .query<{ user_id: string; expires_at: string }, [string]>("SELECT user_id, expires_at FROM sessions WHERE token_hash = ?")
      .get(tokenHash);
    if (!row) return null;
    if (Date.parse(row.expires_at) <= Date.now()) {
      this.db.run("DELETE FROM sessions WHERE token_hash = ?", [tokenHash]);
      return null;
    }
    return this.user(row.user_id);
  }

  endSession(tokenHash: string): void {
    this.db.run("DELETE FROM sessions WHERE token_hash = ?", [tokenHash]);
  }

  // ── the two GitHub round trips ───────────────────────────────────────

  putState(state: string, kind: string, redirect: string | null): void {
    this.db.run("DELETE FROM oauth_states WHERE created_at < ?", [new Date(Date.now() - 15 * 60_000).toISOString()]);
    this.db.run("INSERT OR REPLACE INTO oauth_states (state, kind, redirect, created_at) VALUES (?, ?, ?, ?)", [
      state,
      kind,
      redirect,
      new Date().toISOString(),
    ]);
  }

  /** Takes the state — one use only, which is what makes a replayed callback fail. */
  takeState(state: string): { kind: string; redirect: string | null } | null {
    const row = this.db
      .query<{ kind: string; redirect: string | null; created_at: string }, [string]>(
        "SELECT kind, redirect, created_at FROM oauth_states WHERE state = ?",
      )
      .get(state);
    if (!row) return null;
    this.db.run("DELETE FROM oauth_states WHERE state = ?", [state]);
    if (Date.parse(row.created_at) < Date.now() - 15 * 60_000) return null;
    return { kind: row.kind, redirect: row.redirect };
  }

  // ── projects ─────────────────────────────────────────────────────────

  createProject(p: Omit<ProjectRow, "createdAt" | "archivedAt" | "rev">): ProjectRow {
    const now = new Date().toISOString();
    this.db.run(
      `INSERT INTO projects (id, user_id, name, repo_full_name, repo_private, default_branch, installation_id,
        agent_id, environment_id, vault_id, runtime, model, rev, instructions, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
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
    return this.project(p.id)!;
  }

  project(id: string): ProjectRow | null {
    const r = this.db.query<RawProject, [string]>("SELECT * FROM projects WHERE id = ?").get(id);
    return r ? toProject(r) : null;
  }

  projectsOf(userId: string): ProjectRow[] {
    return this.db
      .query<RawProject, [string]>("SELECT * FROM projects WHERE user_id = ? AND archived_at IS NULL ORDER BY created_at")
      .all(userId)
      .map(toProject);
  }

  renameProject(id: string, name: string): void {
    this.db.run("UPDATE projects SET name = ? WHERE id = ?", [name, id]);
  }

  setInstructions(id: string, instructions: string): void {
    this.db.run("UPDATE projects SET instructions = ? WHERE id = ?", [instructions, id]);
  }

  setModel(id: string, model: string): void {
    this.db.run("UPDATE projects SET model = ? WHERE id = ?", [model, id]);
  }

  /**
   * Bump the settings revision, and return the new one.
   *
   * Called whenever something Fountain injects at session start changes — a
   * secret, an MCP server, a skill, the system prompt. Tracks already open
   * carry the old number in their `channel_id` and are badged as running older
   * settings, which is true and cannot be worked out any other way.
   */
  bumpRev(id: string): number {
    this.db.run("UPDATE projects SET rev = rev + 1 WHERE id = ?", [id]);
    return this.db.query<{ rev: number }, [string]>("SELECT rev FROM projects WHERE id = ?").get(id)?.rev ?? 1;
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
  rebindAgent(id: string, agentId: string): void {
    this.db.run("UPDATE projects SET agent_id = ? WHERE id = ?", [agentId, id]);
  }

  archiveProject(id: string): void {
    this.db.run("UPDATE projects SET archived_at = ? WHERE id = ?", [new Date().toISOString(), id]);
  }

  // ── tracks ───────────────────────────────────────────────────────────

  createTrack(t: Omit<TrackRow, "createdAt" | "openedAt" | "closedAt">): TrackRow {
    this.db.run(
      `INSERT INTO tracks (id, project_id, conversation_id, slug, title, branch, workdir,
        origin_kind, origin_base, origin_number, origin_title, origin_url, rev, created_at, created_by_login)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
    return this.track(t.id)!;
  }

  track(id: string): TrackRow | null {
    const r = this.db.query<RawTrack, [string]>("SELECT * FROM tracks WHERE id = ?").get(id);
    return r ? toTrack(r) : null;
  }

  trackByConversation(conversationId: string): TrackRow | null {
    const r = this.db.query<RawTrack, [string]>("SELECT * FROM tracks WHERE conversation_id = ?").get(conversationId);
    return r ? toTrack(r) : null;
  }

  tracksOf(projectId: string, includeClosed = false): TrackRow[] {
    const sql = includeClosed
      ? "SELECT * FROM tracks WHERE project_id = ? ORDER BY created_at"
      : "SELECT * FROM tracks WHERE project_id = ? AND closed_at IS NULL ORDER BY created_at";
    return this.db.query<RawTrack, [string]>(sql).all(projectId).map(toTrack);
  }

  /** Whether a slug is free right now — the unique index enforces it, this explains it. */
  slugTaken(projectId: string, slug: string): boolean {
    return !!this.db
      .query<{ n: number }, [string, string]>(
        "SELECT COUNT(*) AS n FROM tracks WHERE project_id = ? AND slug = ? AND closed_at IS NULL",
      )
      .get(projectId, slug)?.n;
  }

  attachConversation(trackId: string, conversationId: string): void {
    this.db.run("UPDATE tracks SET conversation_id = ? WHERE id = ?", [conversationId, trackId]);
  }

  markOpened(trackId: string): void {
    this.db.run("UPDATE tracks SET opened_at = COALESCE(opened_at, ?) WHERE id = ?", [new Date().toISOString(), trackId]);
  }

  renameTrack(trackId: string, title: string): void {
    this.db.run("UPDATE tracks SET title = ? WHERE id = ?", [title, trackId]);
  }

  closeTrack(trackId: string): void {
    this.db.run("UPDATE tracks SET closed_at = ? WHERE id = ?", [new Date().toISOString(), trackId]);
  }

  // ── who else is in a track ───────────────────────────────────────────

  addMember(trackId: string, userId: string, invitedBy: string): void {
    this.db.run(
      "INSERT OR IGNORE INTO track_members (track_id, user_id, invited_by, created_at) VALUES (?, ?, ?, ?)",
      [trackId, userId, invitedBy, new Date().toISOString()],
    );
  }

  removeMember(trackId: string, userId: string): void {
    this.db.run("DELETE FROM track_members WHERE track_id = ? AND user_id = ?", [trackId, userId]);
  }

  isMember(trackId: string, userId: string): boolean {
    return !!this.db
      .query<{ n: number }, [string, string]>("SELECT COUNT(*) AS n FROM track_members WHERE track_id = ? AND user_id = ?")
      .get(trackId, userId)?.n;
  }

  /** Everyone invited to a track, oldest invitation first. Excludes the owner. */
  membersOf(trackId: string): UserRow[] {
    return this.db
      .query<RawUser, [string]>(
        `SELECT u.* FROM track_members m JOIN users u ON u.id = m.user_id
         WHERE m.track_id = ? ORDER BY m.created_at`,
      )
      .all(trackId)
      .map(toUser);
  }

  /** The tracks this person was invited to, across every project. */
  memberTracks(userId: string): TrackRow[] {
    return this.db
      .query<RawTrack, [string]>(
        `SELECT t.* FROM track_members m JOIN tracks t ON t.id = m.track_id
         WHERE m.user_id = ? AND t.closed_at IS NULL ORDER BY t.created_at`,
      )
      .all(userId)
      .map(toTrack);
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
  searchUsers(q: string, excludeUserId: string, limit = 8): UserRow[] {
    const like = `%${q}%`;
    const prefix = `${q}%`;
    return this.db
      .query<RawUser, [string, string, string, string, number]>(
        `SELECT * FROM users
         WHERE id != ? AND (login LIKE ? COLLATE NOCASE OR name LIKE ? COLLATE NOCASE)
         ORDER BY CASE WHEN login LIKE ? COLLATE NOCASE THEN 0 ELSE 1 END, login
         LIMIT ?`,
      )
      .all(excludeUserId, like, like, prefix, limit)
      .map(toUser);
  }

  userByLogin(login: string): UserRow | null {
    const r = this.db.query<RawUser, [string]>("SELECT * FROM users WHERE login = ? COLLATE NOCASE").get(login);
    return r ? toUser(r) : null;
  }

  // ── invitations to somebody who is not here yet ──────────────────────

  addInvite(input: { trackId: string; githubId: string; login: string; avatarUrl: string | null; invitedBy: string }): void {
    this.db.run(
      `INSERT INTO track_invites (track_id, github_id, login, avatar_url, invited_by, created_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(track_id, github_id) DO UPDATE SET login = excluded.login, avatar_url = excluded.avatar_url`,
      [input.trackId, input.githubId, input.login, input.avatarUrl, input.invitedBy, new Date().toISOString()],
    );
  }

  invitesOf(trackId: string): { githubId: string; login: string; avatarUrl: string | null }[] {
    return this.db
      .query<{ github_id: string; login: string; avatar_url: string | null }, [string]>(
        "SELECT github_id, login, avatar_url FROM track_invites WHERE track_id = ? ORDER BY created_at",
      )
      .all(trackId)
      .map((r) => ({ githubId: r.github_id, login: r.login, avatarUrl: r.avatar_url }));
  }

  removeInviteByLogin(trackId: string, login: string): boolean {
    const before = this.invitesOf(trackId).length;
    this.db.run("DELETE FROM track_invites WHERE track_id = ? AND login = ? COLLATE NOCASE", [trackId, login]);
    return this.invitesOf(trackId).length < before;
  }

  /**
   * Turn every invitation waiting for this person into a membership.
   *
   * Run once, on the sign-in that creates or refreshes their account. Matching
   * is on the GitHub id the profile just came back with, so an invitation sent
   * to a login they have since changed still finds them, and one sent to a
   * login somebody *else* now holds does not.
   *
   * Returns the tracks they just joined, so the sign-in can say so.
   */
  claimInvites(userId: string, githubId: string): TrackRow[] {
    const pending = this.db
      .query<{ track_id: string }, [string]>("SELECT track_id FROM track_invites WHERE github_id = ?")
      .all(githubId);
    const joined: TrackRow[] = [];
    for (const { track_id } of pending) {
      const track = this.track(track_id);
      // A track closed while the invitation sat unclaimed is not somewhere to
      // arrive. Drop the invitation rather than granting a dead seat.
      if (track && !track.closedAt) {
        this.addMember(track_id, userId, "invite");
        joined.push(track);
      }
    }
    this.db.run("DELETE FROM track_invites WHERE github_id = ?", [githubId]);
    return joined;
  }

  // ── the link ─────────────────────────────────────────────────────────

  putLink(trackId: string, tokenHash: string, createdBy: string, ttlMs: number): void {
    const now = Date.now();
    this.db.run(
      `INSERT INTO track_links (track_id, token_hash, created_by, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(track_id) DO UPDATE SET
         token_hash = excluded.token_hash, created_by = excluded.created_by,
         created_at = excluded.created_at, expires_at = excluded.expires_at`,
      [trackId, tokenHash, createdBy, new Date(now).toISOString(), new Date(now + ttlMs).toISOString()],
    );
  }

  linkOf(trackId: string): { createdAt: string; expiresAt: string } | null {
    const r = this.db
      .query<{ created_at: string; expires_at: string }, [string]>(
        "SELECT created_at, expires_at FROM track_links WHERE track_id = ?",
      )
      .get(trackId);
    if (!r) return null;
    return { createdAt: r.created_at, expiresAt: r.expires_at };
  }

  dropLink(trackId: string): void {
    this.db.run("DELETE FROM track_links WHERE track_id = ?", [trackId]);
  }

  /** The track a link opens, or null if it is unknown, revoked or expired. */
  trackForLink(tokenHash: string): TrackRow | null {
    const r = this.db
      .query<{ track_id: string; expires_at: string }, [string]>(
        "SELECT track_id, expires_at FROM track_links WHERE token_hash = ?",
      )
      .get(tokenHash);
    if (!r) return null;
    if (Date.parse(r.expires_at) <= Date.now()) return null;
    const track = this.track(r.track_id);
    return track && !track.closedAt ? track : null;
  }

  close(): void {
    this.db.close();
  }
}

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
