/**
 * The contract between the browser and the switchyard server.
 *
 * Every one of these shapes is served from `/api/...`. Nothing here is a
 * Fountain shape: the browser has no Fountain key, no Fountain session and no
 * idea what an environment id is. It talks to this server, and this server
 * does the Fountain work. `fountain-types.ts` is the other side of that wall
 * and is imported only by `server/`.
 *
 * That wall is the app's one structural decision. Sign-in is GitHub, so a
 * person here has no Fountain account to spend — the machine runs on the
 * server's account, and everything the browser can ask for has to be a shape
 * this file names.
 */

// ── who is here ────────────────────────────────────────────────────────

/** Somebody who can be invited, or who is already in. */
export interface Person {
  login: string;
  name: string | null;
  avatarUrl: string | null;
  /**
   * Invited, but not here yet.
   *
   * Somebody can be invited before they have ever signed in — the invitation
   * waits on their GitHub account rather than on a row we hold — so a track's
   * people list has two kinds of entry and the difference is worth showing.
   * A pending person cannot read anything yet.
   */
  pending?: boolean;
}

/**
 * Somebody with a track open right now.
 *
 * Not the same list as `Track.people`: that is who *may* reach it, this is who
 * is looking. Somebody can be on one and not the other in both directions —
 * invited and away, or the owner who is always allowed and currently absent.
 */
export interface Presence {
  login: string;
  name: string | null;
  avatarUrl: string | null;
  /** Mid-sentence in the composer, as of the last three seconds. */
  typing: boolean;
}

/** The one live invite link a track may have. */
export interface TrackLink {
  /** Absolute, and only ever returned to the owner at the moment it is minted. */
  url: string | null;
  createdAt: string;
  expiresAt: string;
}

export interface Viewer {
  /** GitHub numeric id, as a string. */
  id: string;
  login: string;
  name: string | null;
  avatarUrl: string | null;
  /** Whether this account has the GitHub App installed anywhere we can see. */
  hasInstallation: boolean;
}

/** `GET /api/session` — the whole of what the shell needs before it renders. */
export interface SessionInfo {
  viewer: Viewer | null;
  /** Where to send a browser to sign in. Absolute, at GitHub. */
  signInUrl: string;
  /** Where to send a browser to install or configure the App. Absolute, at GitHub. */
  installUrl: string;
  /** What this deployment can actually do — see `Capabilities`. */
  capabilities: Capabilities;
}

/**
 * What is switched on here, decided by the server's environment rather than by
 * a build flag.
 *
 * The UI reads this instead of guessing, because the honest answer differs per
 * deployment: a switchyard with no Sprites token has no terminal, and a panel
 * that pretends otherwise is worse than one that says so. Every `false` here
 * has a designed empty state behind it, not a broken button.
 */
export interface Capabilities {
  /** A Sprites token is configured, so the terminal and the run panel are live. */
  exec: boolean;
  /** A GitHub App is configured, so repositories, PRs, issues and checks work. */
  github: boolean;
  /** Fountain offers vaults, so brokered credentials are available. */
  vaults: boolean;
}

// ── repositories, from GitHub ──────────────────────────────────────────

export interface RepoRef {
  /** `owner/name`. */
  fullName: string;
  owner: string;
  name: string;
  private: boolean;
  defaultBranch: string;
  description: string | null;
  /** ISO 8601. Sorted on by the picker: what you touched last is what you want. */
  pushedAt: string | null;
  language: string | null;
  /** The installation that can see it. */
  installationId: number;
}

export interface BranchRef {
  name: string;
  sha: string;
  /** True for the repository's default branch. */
  isDefault: boolean;
}

export interface PullRef {
  number: number;
  title: string;
  author: string | null;
  headRef: string;
  baseRef: string;
  draft: boolean;
  updatedAt: string;
  /**
   * Where it got to.
   *
   * A merged pull request is the most interesting thing a finished branch has,
   * so the Checks panel shows it rather than reporting that there is no *open*
   * one — which is true, and reads as "nobody ever opened one".
   */
  state?: "open" | "closed" | "merged";
  url?: string | null;
}

export interface IssueRef {
  number: number;
  title: string;
  author: string | null;
  labels: string[];
  updatedAt: string;
}

/** `GET /api/projects/:id/checks?ref=` — GitHub's view of a branch. */
export interface CheckRun {
  name: string;
  status: "queued" | "in_progress" | "completed" | string;
  conclusion: "success" | "failure" | "neutral" | "cancelled" | "skipped" | "timed_out" | "action_required" | string | null;
  url: string | null;
  startedAt: string | null;
  completedAt: string | null;
}

export interface ChecksReport {
  ref: string;
  sha: string | null;
  /** Null when the branch has never been pushed — which is not a failure. */
  pushed: boolean;
  runs: CheckRun[];
  /** An open pull request for this branch, if there is one. */
  pull: PullRef | null;
}

// ── projects ───────────────────────────────────────────────────────────

/**
 * A project is a machine.
 *
 * Conductor's word for this is also "project", and it means roughly the same
 * thing: a repository plus the agent that works on it. Here it is exactly
 * three Fountain records — an agent, an environment and a vault — whose ids
 * never move, which is what makes the disk survive every change you make to
 * the project afterwards.
 */
export interface Project {
  id: string;
  name: string;
  /** `owner/name`, or null for a project with no repository yet. */
  repo: string | null;
  repoPrivate: boolean;
  defaultBranch: string | null;
  /** Where the clone lands on the machine: `/workspace/<name>`. */
  repoPath: string | null;
  runtime: string;
  model: string;
  /** Bumped whenever settings change; carried in each track's `channel_id`. */
  rev: number;
  /** The machine, once there is one. */
  machine: MachineState;
  createdAt: string;
  /** The GitHub login of whoever made it. */
  ownerLogin: string;
  /**
   * What the caller is here.
   *
   * `member` means they were invited to one or more *tracks* on this project,
   * not to the project. They see those tracks and nothing else of it: no
   * settings, no rebuild, no other tracks, no track of their own. The UI reads
   * this rather than comparing logins, so there is one place that decides.
   */
  role: "owner" | "member";
}

export interface MachineState {
  sandboxId: string | null;
  status: "none" | "pending" | "starting" | "ready" | "suspended" | "terminated" | "failed";
  /** Present only when the server holds a Sprites token and the sandbox named one. */
  spriteName: string | null;
}

/** What a project's settings panel edits. Every field is a mutation in place. */
export interface ProjectSettings {
  name: string;
  setupScript: string;
  /** `{"apt": ["ripgrep"], "npm": ["typescript"]}` — keyed by manager, never a flat list. */
  packages: Record<string, string[]>;
  /** Environment secrets: keys only, values are write-only. */
  envKeys: string[];
  vaultKeys: string[];
  model: string;
  /** Extra instructions appended to the agent's system prompt. */
  instructions: string;
}

// ── tracks ─────────────────────────────────────────────────────────────

/**
 * A track is a worktree, and a conversation about it.
 *
 * Conductor calls these threads or workspaces. Switchyard calls them tracks
 * because that is what they are in a yard: parallel lines off one main, each
 * holding something different, all on the same ground.
 */
export interface Track {
  id: string;
  projectId: string;
  /** The conversation on Fountain. Null only in the instant between the two. */
  conversationId: string | null;
  slug: string;
  title: string;
  branch: string;
  /** `/home/sprite/work/<slug>`. */
  workdir: string;
  origin: TrackOriginInfo;
  status: "opening" | "ready" | "running" | "failed" | "closed";
  /** True when the track opened before the project's current settings revision. */
  stale: boolean;
  /** Set once the opening turn reports back; null while it is still cutting. */
  openedAt: string | null;
  lastActiveAt: string | null;
  turnCount: number;
  createdAt: string;
  createdByLogin: string;
  /** Everyone who can reach this track, the owner first. One entry until shared. */
  people: Person[];
  /** What the caller may do here. */
  role: "owner" | "member";
  /**
   * The machine has said something since this person last looked.
   *
   * Per person, not per track: a shared track read by one of three people is
   * still unread for the other two.
   */
  unread: boolean;
}

export interface TrackOriginInfo {
  kind: "branch" | "pr" | "issue" | "blank";
  base: string | null;
  number: number | null;
  title: string | null;
  /** GitHub URL for a PR or issue origin. */
  url: string | null;
}

/** The ribbon at the top of a track — the four lines Conductor shows on a new thread. */
export interface TrackHeader {
  /** "You're in a new copy of fountain called kyoto". */
  copyOf: string | null;
  /** "Branched jhgaylor/kyoto from origin/main". */
  branchedFrom: { branch: string; base: string } | null;
  /** "Created kyoto and copied 1480 files" — null until the machine says a number. */
  created: { dir: string; files: number | null } | null;
  /** Whether this project has a setup script yet. */
  hasSetupScript: boolean;
}

// ── the machine's own surfaces ─────────────────────────────────────────

export interface FileEntry {
  name: string;
  type: "file" | "directory" | "symlink" | "other" | string;
  size: number | null;
}

export interface FileListing {
  path: string;
  entries: FileEntry[];
  truncated: boolean;
}

export interface FileContent {
  path: string;
  size: number;
  truncated: boolean;
  encoding: string;
  content: string;
}

export interface DiffReport {
  path: string;
  repoRoot: string;
  diff: string;
  truncated: boolean;
  /** Parsed from the diff so the panel can list files without re-parsing per render. */
  files: DiffFile[];
}

export interface DiffFile {
  path: string;
  added: number;
  removed: number;
  status: "added" | "modified" | "deleted" | "renamed";
}

// ── the terminal ───────────────────────────────────────────────────────

/**
 * One command, run on the machine over Sprites.
 *
 * Not a PTY. Sprites' exec is request/response over one HTTP call, so this is
 * a shell that runs a command and gives you its output — which is most of what
 * a terminal is used for and none of what `vim` needs. The panel says so
 * rather than letting somebody discover it.
 */
export interface ExecRequest {
  command: string;
  /** Defaults to the track's workdir. */
  cwd?: string;
  timeoutSec?: number;
}

export interface ExecResult {
  stdout: string;
  stderr: string;
  code: number;
  /** Where the shell ended up, so the next command starts there. */
  cwd: string;
  timedOut: boolean;
  durationMs: number;
}

// ── the transcript ─────────────────────────────────────────────────────

/**
 * One turn, as Fountain records it.
 *
 * The *prompt* lives here and the *output* lives in the event log, joined on
 * `turn_id`. Two calls rather than one because they are genuinely two things:
 * a turn is what somebody asked for, and an event is a byte the machine
 * produced on the way to answering. A transcript that read only the events
 * would render an agent talking to itself.
 */
export interface TurnRecord {
  id: string;
  prompt: string | null;
  /** `user` for a person's prompt; `autonomous` marks a background cycle. */
  origin: string | null;
  status: string | null;
  insertedAt: string | null;
}

export interface TranscriptPage {
  turns: TurnRecord[];
  events: unknown[];
}

// ── streams ────────────────────────────────────────────────────────────

/** What `GET /api/projects/:id/stream` pushes, beside Fountain's own log events. */
export type ProjectEvent =
  | { event: "tracks"; data: { projectId: string } }
  | { event: "machine"; data: MachineState }
  | { event: "turn"; data: { trackId: string; status: Track["status"] } }
  | { event: "settings"; data: { rev: number } }
  /** The membership of a track changed: somebody was invited, or left. */
  | { event: "people"; data: { trackId: string } }
  /**
   * Who has a track open, and who is typing in it.
   *
   * Carries the whole set rather than a delta. The set is small, the events
   * are frequent, and a client that missed one delta would be wrong until the
   * next person moved — which on a quiet track is a long time.
   */
  | { event: "here"; data: { trackId: string; present: Presence[] } };

// ── errors ─────────────────────────────────────────────────────────────

export interface ApiErrorBody {
  error: string;
  message: string;
  [k: string]: unknown;
}
