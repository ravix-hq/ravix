/**
 * Fountain, on this server's key.
 *
 * Every other app in this suite hands the browser a Fountain key of its own
 * (dns-desk, arena) or holds one key per signed-in person (paddock, salon).
 * Switchyard holds exactly one, for everybody, because sign-in is GitHub and
 * a person here has no Fountain account to spend. That makes this file the
 * whole of the app's access to Fountain — there is no proxy through which a
 * browser can reach a path this file does not name.
 *
 * So it is typed rather than forwarding. The one exception is `stream`, which
 * has to hand back a live body untouched or server-sent events stop being
 * events.
 */
import { HttpError } from "./http";
import type { Agent, Catalog, Conversation, Environment, LogEvent, Repository, Sandbox, SandboxDiff, SandboxFile, SandboxListing, Vault } from "../shared/fountain-types";

export class FountainHttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string | null,
    message: string,
  ) {
    super(message);
  }
}

/** One entry of `GET /api/conversations/:id/turns`. */
export interface RawTurn {
  id: string;
  prompt?: string | null;
  origin?: string | null;
  status?: string | null;
  inserted_at?: string | null;
  [k: string]: unknown;
}

export interface ConversationSummary {
  id: string;
  title: string | null;
  sandbox_id: string | null;
  agent_id: string | null;
  environment_id?: string | null;
  vault_id?: string | null;
  runtime: string;
  status: string;
  channel_id: string | null;
  turn_count: number;
  last_active_at: string | null;
  inserted_at: string;
  [k: string]: unknown;
}

export class Fountain {
  constructor(
    private readonly baseUrl: string,
    private readonly apiKey: string,
  ) {}

  // ── what this Fountain can do ────────────────────────────────────────

  catalog(): Promise<Catalog> {
    return this.data<Catalog>("GET", "/api/catalog");
  }

  me(): Promise<{ id: string; email: string }> {
    return this.data("GET", "/api/auth/me");
  }

  // ── the three records a project is ───────────────────────────────────

  createEnvironment(body: {
    name: string;
    repositories?: Repository[];
    packages?: Record<string, string[]>;
    setup_script?: string;
  }): Promise<Environment> {
    return this.data("POST", "/api/environments", body);
  }

  getEnvironment(id: string): Promise<Environment> {
    return this.data("GET", `/api/environments/${encodeURIComponent(id)}`);
  }

  updateEnvironment(id: string, body: Partial<Environment>): Promise<Environment> {
    return this.data("PUT", `/api/environments/${encodeURIComponent(id)}`, body);
  }

  createVault(body: { name: string }): Promise<Vault> {
    return this.data("POST", "/api/vaults", body);
  }

  createAgent(body: Record<string, unknown>): Promise<Agent> {
    return this.data("POST", "/api/agents", body);
  }

  getAgent(id: string): Promise<Agent> {
    return this.data("GET", `/api/agents/${encodeURIComponent(id)}`);
  }

  updateAgent(id: string, body: Record<string, unknown>): Promise<Agent> {
    return this.data("PUT", `/api/agents/${encodeURIComponent(id)}`, body);
  }

  deleteAgent(id: string): Promise<void> {
    return this.data("DELETE", `/api/agents/${encodeURIComponent(id)}`);
  }

  deleteEnvironment(id: string): Promise<void> {
    return this.data("DELETE", `/api/environments/${encodeURIComponent(id)}`);
  }

  deleteVault(id: string): Promise<void> {
    return this.data("DELETE", `/api/vaults/${encodeURIComponent(id)}`);
  }

  /**
   * Write one secret.
   *
   * The only call in this file whose *body* must never be logged, which is why
   * `request` logs the path and the status and nothing else. `store` picks
   * which of the two places it goes: the environment puts it in the box as an
   * ordinary env var, the vault keeps it off the box entirely and lets
   * Fountain's egress broker substitute it in flight. Switchyard's clone token
   * goes in the vault for exactly that reason.
   */
  putSecret(store: "environments" | "vaults", id: string, key: string, value: string): Promise<void> {
    // `POST /secrets` with both fields, not `PUT /secrets/:key`. Fountain's
    // secret request requires `key` and `value` together, and a write to an
    // existing key overwrites it — so there is one call rather than a create
    // and an update, and no 404 to handle on the first write of a rotation.
    return this.data("POST", `/api/${store}/${encodeURIComponent(id)}/secrets`, { key, value });
  }

  deleteSecret(store: "environments" | "vaults", id: string, key: string): Promise<void> {
    return this.data("DELETE", `/api/${store}/${encodeURIComponent(id)}/secrets/${encodeURIComponent(key)}`);
  }

  secretKeys(store: "environments" | "vaults", id: string): Promise<{ key: string; updated_at?: string | null }[]> {
    return this.data("GET", `/api/${store}/${encodeURIComponent(id)}/secrets`);
  }

  // ── conversations ────────────────────────────────────────────────────

  async listConversations(agentId?: string): Promise<ConversationSummary[]> {
    const qs = agentId ? `?${new URLSearchParams({ agent_id: agentId })}` : "";
    return this.data<ConversationSummary[]>("GET", `/api/conversations${qs}`);
  }

  getConversation(id: string): Promise<Conversation> {
    return this.data("GET", `/api/conversations/${encodeURIComponent(id)}`);
  }

  /**
   * Open a conversation on a project's machine.
   *
   * The whole identity goes on every attach, not half of it. A disk is built
   * for `(agent, environment, vault)`, and naming only the agent asks for a
   * *different* identity — one with no environment and no vault — which
   * Fountain refuses as `sandbox_identity_mismatch`. This is the single most
   * expensive thing to get wrong in the app: it does not fail loudly, it hands
   * you a second machine.
   */
  createConversation(body: {
    agent_id: string;
    environment_id?: string | null;
    vault_id?: string | null;
    sandbox_id?: string | null;
    title?: string;
    channel_id: string;
    /**
     * The first turn, sent in the same call.
     *
     * Not an optimisation. Every app in this suite that starts a *fresh*
     * conversation sends its prompt here, and paddock sending it separately is
     * the one difference that made provisioning a machine start answering 422.
     * So a track's opening turn rides along with the launch that provisions
     * the box; only an attach to a box that already exists prompts separately.
     */
    prompt?: string;
  }): Promise<Conversation> {
    return this.data("POST", "/api/conversations", {
      agent_id: body.agent_id,
      ...(body.environment_id ? { environment_id: body.environment_id } : {}),
      ...(body.vault_id ? { vault_id: body.vault_id } : {}),
      // Attaching ignores `sandbox_mode`; provisioning needs it, and
      // `persistent` is what makes the disk the identity's home rather than
      // this one conversation's.
      ...(body.sandbox_id ? { sandbox_id: body.sandbox_id } : { sandbox_mode: "persistent" }),
      ...(body.title ? { title: body.title } : {}),
      ...(body.prompt ? { prompt: body.prompt } : {}),
      channel_id: body.channel_id,
      // Never resume. A `channel_id` on create makes Fountain hand back the
      // latest live conversation for the same (agent, vault, channel) and
      // answer 200 instead of opening one — right for a chat harness, wrong
      // here, where a slug is already unique per live track and a resume would
      // quietly give two tracks one conversation.
      fresh: true,
    });
  }

  prompt(conversationId: string, text: string, images: { data: string; media_type: string }[] = []): Promise<unknown> {
    return this.data("POST", `/api/conversations/${encodeURIComponent(conversationId)}/prompts`, {
      prompt: text,
      ...(images.length ? { images } : {}),
    });
  }

  interrupt(conversationId: string): Promise<unknown> {
    return this.data("POST", `/api/conversations/${encodeURIComponent(conversationId)}/interrupt`, {});
  }

  terminate(conversationId: string): Promise<unknown> {
    return this.data("POST", `/api/conversations/${encodeURIComponent(conversationId)}/terminate`, {});
  }

  turns(conversationId: string): Promise<RawTurn[]> {
    return this.data("GET", `/api/conversations/${encodeURIComponent(conversationId)}/turns`);
  }

  /**
   * The stored log, oldest first.
   *
   * `limit` caps at a thousand and defaults to a hundred, which is not enough
   * for a track somebody has been working in — a partial scrollback that looks
   * complete is worse than a slow one.
   */
  events(conversationId: string): Promise<LogEvent[]> {
    return this.data("GET", `/api/conversations/${encodeURIComponent(conversationId)}/events?limit=1000`);
  }

  /**
   * The live transcript, handed back with its body still open.
   *
   * Not `data()`: reading this to completion is what a server-sent stream
   * never does. The caller pipes it straight to the browser.
   */
  stream(conversationId: string, signal: AbortSignal): Promise<Response> {
    return this.raw("GET", `/api/conversations/${encodeURIComponent(conversationId)}/stream`, {
      accept: "text/event-stream",
      signal,
    });
  }

  // ── reading the machine, for free ────────────────────────────────────

  /**
   * One sandbox, in full.
   *
   * The only place `sprite_name` actually appears. `GET /api/conversations`
   * carries a `sandbox_id` but serves `"sandbox": null` — the embedded object
   * is a detail-endpoint field — so a terminal that read the list would
   * conclude, wrongly and permanently, that this machine is not on Sprites.
   */
  sandbox(id: string): Promise<Sandbox> {
    return this.data("GET", `/api/sandboxes/${encodeURIComponent(id)}`);
  }


  listing(sandboxId: string, path: string): Promise<SandboxListing> {
    return this.data("GET", `/api/sandboxes/${encodeURIComponent(sandboxId)}/files?${new URLSearchParams({ path })}`);
  }

  file(sandboxId: string, path: string): Promise<SandboxFile> {
    return this.data("GET", `/api/sandboxes/${encodeURIComponent(sandboxId)}/file?${new URLSearchParams({ path })}`);
  }

  diff(sandboxId: string, path: string): Promise<SandboxDiff> {
    return this.data("GET", `/api/sandboxes/${encodeURIComponent(sandboxId)}/diff?${new URLSearchParams({ path })}`);
  }

  // ── plumbing ─────────────────────────────────────────────────────────

  raw(
    method: string,
    path: string,
    init: { body?: BodyInit | null; signal?: AbortSignal; accept?: string } = {},
  ): Promise<Response> {
    const headers: Record<string, string> = { authorization: `Bearer ${this.apiKey}` };
    if (init.accept) headers.accept = init.accept;
    if (init.body != null) headers["content-type"] = "application/json";
    return fetch(`${this.baseUrl}${path}`, {
      method,
      headers,
      body: init.body ?? undefined,
      signal: init.signal ?? AbortSignal.timeout(60_000),
    });
  }

  /** A call whose body is `{data: …}`, unwrapped — which is every one of them. */
  private async data<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await this.raw(method, path, {
      body: body === undefined ? null : JSON.stringify(body),
      accept: "application/json",
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
      const obj = (parsed ?? {}) as { error?: unknown; message?: unknown };
      const code = typeof obj.error === "string" ? obj.error : null;
      const message = typeof obj.message === "string" ? obj.message : (code ?? `${res.status} ${res.statusText}`);
      // The path and the status, never the body we sent — it may be a secret
      // value on its way to /secrets/:key.
      if (res.status >= 400) console.error(`switchyard: fountain ${res.status} on ${method} ${path.split("?")[0]}: ${message}`);
      throw new FountainHttpError(res.status, code, message);
    }
    const wrapped = parsed as { data?: T } | null;
    return (wrapped && typeof wrapped === "object" && "data" in wrapped ? wrapped.data : parsed) as T;
  }
}

/** A Fountain failure as one of ours, preserving what the caller needs. */
export function asHttpError(err: unknown, whatFor: string): HttpError {
  if (err instanceof FountainHttpError) {
    if (err.status === 401 || err.status === 403) {
      return new HttpError(502, "fountain_rejected", "Fountain rejected this deployment's key. Switchyard cannot build machines until that is fixed.");
    }
    if (err.code === "sandbox_at_capacity") {
      return new HttpError(409, "machine_busy", "This machine is already taking a turn. One track at a time — yours is queued.");
    }
    if (err.code === "sandbox_identity_mismatch") {
      return new HttpError(409, "identity_mismatch", "This project's machine no longer matches its identity. Rebuild it from the project menu.");
    }
    return new HttpError(err.status >= 500 ? 502 : err.status, err.code ?? "fountain_error", err.message);
  }
  return new HttpError(502, "fountain_unreachable", `Could not reach Fountain to ${whatFor}.`);
}
