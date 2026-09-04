// Shapes as served by the Fountain API, narrowed to what switchyard reads.
// Lifted from apps/fountain-conversations/src/api/types.ts, which tracks
// docs/api.md; fields this app never touches are left off on purpose.

export type SandboxMode = "ephemeral" | "persistent";
export type SandboxStatus = "pending" | "starting" | "ready" | "suspended" | "terminated" | "failed";
export type ConversationStatus = "pending" | "running" | "idle" | "failed" | "terminated";

/** One machine, as a conversation embeds it (`conversation.sandbox`). */
export interface Sandbox {
  id: string;
  sprite_name?: string;
  status: SandboxStatus;
  provider?: string | null;
  /**
   * The identity the disk was built from (ADR 0023). A launch must match all
   * three to attach with `sandbox_id`; this is the whole reason switchyard keeps
   * one agent, one environment and one vault and mutates them in place
   * instead of making new ones. See `lib/machine.ts`.
   */
  agent_id?: string | null;
  environment_id?: string | null;
  vault_id?: string | null;
  /** `persistent`: the agent identity's home, shared by its conversations and kept when one ends. */
  mode?: SandboxMode;
  url?: string | null;
}

export interface Conversation {
  id: string;
  title: string | null;
  sandbox_id: string | null;
  sandbox: Sandbox | null;
  agent_id: string | null;
  vault_id: string | null;
  environment_id: string | null;
  runtime: string;
  status: ConversationStatus;
  channel_id: string | null;
  turn_count: number;
  last_active_at: string | null;
  inserted_at: string;
  updated_at?: string;
}

/** A repository an environment clones into the box. */
export interface Repository {
  url: string;
  mount_path: string;
  ref?: string | null;
  /** Names an environment secret holding the clone credential. Never the credential. */
  secret_key?: string | null;
}

export interface Environment {
  id: string;
  name: string;
  repositories?: Repository[] | null;
  /**
   * Keyed by package manager, not a flat list: `{"apt": ["ripgrep", "jq"]}`.
   * Fountain rejects an array outright — `{"packages":["Invalid object. Got:
   * array"]}` — which is how this was found. See `apps/salon/server/projects.ts`.
   */
  packages?: Record<string, string[]> | null;
  setup_script?: string | null;
}

export interface Vault {
  id: string;
  name: string;
}

/** One entry of `GET /api/{environments,vaults}/:id/secrets`. A key, never a value. */
export interface SecretKey {
  key: string;
  updated_at?: string | null;
}

export interface Agent {
  id: string;
  name: string;
  /** An agent's default. Switchyard's is `persistent`: the machine is the point. */
  sandbox_mode?: SandboxMode | null;
  description?: string | null;
  system?: string | null;
  model: string;
  runtime: string;
  environment_id?: string | null;
  vault_id?: string | null;
  skills?: unknown[] | null;
  mcp_servers?: Record<string, unknown> | null;
  metadata?: Record<string, unknown> | null;
}

/**
 * One entry of the catalog's `mcp_servers`: a remote MCP server whose
 * authorization chain Fountain has watched complete.
 *
 * The claim is narrow and worth keeping narrow in the UI: RFC 9728 → 8414 →
 * 7591 completed against `url` on `verified_on`, by a script rather than a
 * person. It is not an endorsement, it says nothing about the tools the server
 * offers, and the list is a menu rather than a gate — any URL Fountain can
 * discover still works.
 *
 * `dcr` is whether the server registers a client automatically. False means
 * connecting it needs a client id from an app registration of your own, which
 * is a different amount of work and the panel should not pretend otherwise.
 */
export interface CatalogMcpServer {
  slug: string;
  name: string;
  url: string;
  dcr: boolean;
  /** `YYYY-MM-DD`. */
  verified_on: string;
}

/** `GET /api/catalog`: what this Fountain can run. */
export interface Catalog {
  runtimes: string[];
  models: Record<string, string[]>;
  /**
   * What Fountain installs from an environment's `packages` — `apt` and `npm`.
   * It stores another key and ignores it, which is why the Machine panel offers
   * these rather than a text box: a package under a manager Fountain does not
   * know reads as configured and installs nothing.
   */
  package_managers?: string[];
  mcp_servers?: CatalogMcpServer[];
}

/**
 * A provider account the owner signed in to once, whose tokens Fountain holds.
 *
 * Switchyard only ever reads these. Connecting one "needs a browser and a session,
 * so it is not an API operation" — it happens at Fountain's console, and the
 * most switchyard can do is say whether it has happened and link to where it does.
 */
export interface Connection {
  id: string;
  /** The provider's slug. */
  provider: string;
  /** The tenant provider row behind it; null for a platform provider. */
  provider_id: string | null;
  account_email: string | null;
  /** The env var the token is brokered under, e.g. `GITHUB_ACCESS_TOKEN`. */
  env_key: string;
  status: "active" | "revoked" | "expired" | string;
}

/** Where a connection's tokens come from, and where the owner goes to make one. */
export interface ConnectionProvider {
  id: string;
  slug: string;
  name: string;
  /** `oauth2` (your own app registration) or `mcp` (discovered from a URL). */
  kind: string;
  /** Set on `kind: "mcp"` — the remote server this provider was discovered from. */
  mcp_url: string | null;
  /** Absolute, at Fountain. A browser signed in as the owner completes the flow. */
  connect_url: string;
  env_key: string | null;
}

/**
 * What one entry of a directory is. Fountain's word for a directory is
 * `"directory"` — not `"dir"`, which is what this app assumed until a real
 * machine disagreed and every folder rendered as an unopenable file.
 * See `apps/salon/shared/files.ts`, which has carried the same union all along.
 */
export type EntryType = "file" | "directory" | "symlink" | "other";

export interface SandboxEntry {
  name: string;
  type: EntryType | string;
  size: number | null;
}

/** `GET /api/sandboxes/:id/files`: one directory. */
export interface SandboxListing {
  path: string;
  entries: SandboxEntry[];
  truncated: boolean;
}

/** `GET /api/sandboxes/:id/file`: one file's bytes, text or base64, redacted. */
export interface SandboxFile {
  path: string;
  size: number;
  truncated: boolean;
  encoding: string;
  content: string;
}

/** `GET /api/sandboxes/:id/diff`: `git diff` of the repository at `path`. */
export interface SandboxDiff {
  path: string;
  repo_root: string;
  staged: boolean;
  ref: string | null;
  diff: string;
  truncated: boolean;
}

/**
 * One stored log event, as `GET /api/conversations/:id/events` returns it and
 * as `GET /api/events/stream` pushes it. Structurally a superset of the shared
 * `LogEvent` in `@managoat/fountain-app`, so it passes straight to
 * `blocksForTurn` without a cast.
 */
export interface LogEvent {
  id: number;
  kind: "output" | "stage" | string;
  stream: string | null;
  data: string | null;
  stage: string | null;
  state: string | null;
  turn_id: string | null;
  ts: string;
  /** Present on the account-wide stream, which carries every tab at once. */
  conversation_id?: string;
}

export interface Me {
  id: string;
  email: string;
}
