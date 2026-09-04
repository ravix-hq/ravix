/**
 * A tiny mock of *both* halves of switchyard's world, in one process.
 *
 * Every other app in this suite needs a fake Fountain to be developed offline.
 * Switchyard needs a fake GitHub as well, and not as a convenience: sign-in is
 * a GitHub App, so without one there is no session, without a session there is
 * no project, and without a project there is nothing on the screen at all. A
 * mock that covered only Fountain would leave the app permanently on its
 * sign-in page. So this serves three hosts on one port, told apart by prefix:
 *
 *   /api/…      Fountain — machines, conversations, the box's disk
 *   /gh/…       api.github.com
 *   /ghweb/…    github.com, the part a browser visits
 *
 * It is more than a fixture, for the same reason paddock's is. It simulates
 * the *box*: an opening turn that says `git worktree add` actually creates
 * that directory in the fake filesystem, so the Files panel afterwards shows
 * the worktree the transcript just watched being made. And it enforces the two
 * Fountain rules that cost this app the most — `sandbox_identity_mismatch` and
 * `sandbox_at_capacity` — because a mock that accepts what Fountain rejects is
 * not a convenience, it is a place for that class of bug to live.
 *
 *   bun run mock
 *
 * and the startup log prints the exact command line for the server.
 */
import { generateKeyPairSync } from "node:crypto";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { WORKSPACE_ROOT, WORK_ROOT } from "../shared/ids";
import { RECEIPT_PATH } from "../shared/spec";

const PORT = 8793;
const BASE = `http://localhost:${PORT}`;

/**
 * Where switchyard is, as a *browser* reaches it — which is Vite in dev, not
 * the API server. The install flow needs it because GitHub's own
 * `/apps/:slug/installations/new` carries no `redirect_uri`: the real one
 * redirects to the callback registered on the App, and the fake has to be told
 * the same thing.
 */
const APP_URL = (process.env.SWITCHYARD_URL ?? "http://localhost:5183").replace(/\/+$/, "");

const now = () => new Date().toISOString();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── Fountain's state ───────────────────────────────────────────────────

interface Conv {
  id: string;
  title: string | null;
  sandbox_id: string | null;
  agent_id: string;
  vault_id: string | null;
  environment_id: string | null;
  runtime: string;
  status: string;
  channel_id: string | null;
  turn_count: number;
  last_active_at: string | null;
  inserted_at: string;
}

interface Box {
  id: string;
  sprite_name: string;
  status: string;
  provider: string;
  mode: string;
  agent_id: string;
  environment_id: string | null;
  vault_id: string | null;
  url: null;
}

const state = {
  seq: 1,
  turnSeq: 1,
  agents: [] as Record<string, unknown>[],
  environments: [] as Record<string, unknown>[],
  vaults: [] as Record<string, unknown>[],
  /** `${parent}:${id}` → key → value. Values go in and never come back out. */
  secrets: new Map<string, Map<string, string>>(),
  conversations: [] as Conv[],
  /**
   * One box per agent, not one per account. Switchyard's projects each get
   * their own agent precisely so they each get their own machine, and a mock
   * with a single global sandbox would make two projects look like one.
   */
  boxes: new Map<string, Box>(),
  /** The disk, as far as anything here is concerned: absolute path → bytes. */
  files: new Map<string, string>(),
  /** What `git worktree list` would say, for the survey turn. */
  worktrees: new Map<string, { branch: string | null; repoPath: string | null }>(),
  events: new Map<string, unknown[]>(),
  /**
   * The turn records, which are a second list beside the log and not a view of
   * it. Fountain keeps the prompt on the turn; the transcript joins the two on
   * `turn_id`, so a mock that served only the log would leave every bubble
   * without the words that caused it.
   */
  turns: new Map<string, Record<string, unknown>[]>(),
  /** sandbox id → the conversation currently holding it. One turn per box. */
  busy: new Map<string, string>(),
  /** conversation id → its own queue, so a second prompt to it waits its turn. */
  queues: new Map<string, Promise<void>>(),
};

// ── the stream ─────────────────────────────────────────────────────────

interface Sub {
  conversationId: string;
  send: (chunk: string) => void;
}
const subs = new Set<Sub>();

function push(conversationId: string, ev: Record<string, unknown>) {
  const id = state.seq++;
  const full = {
    id,
    conversation_id: conversationId,
    ts: now(),
    stream: null,
    data: null,
    stage: null,
    state: null,
    turn_id: null,
    ...ev,
  };
  const list = state.events.get(conversationId) ?? [];
  list.push(full);
  state.events.set(conversationId, list);
  const frame = `id: ${id}\nevent: message\ndata: ${JSON.stringify(full)}\n\n`;
  for (const sub of subs) if (sub.conversationId === conversationId) sub.send(frame);
}

/**
 * One conversation's transcript as server-sent events.
 *
 * The `: ping` comment every fifteen seconds is not decoration. A track's tab
 * holds this open for as long as somebody is looking at it, and an idle SSE
 * connection is closed by a proxy or by the browser itself at around a minute
 * — after which the transcript silently stops moving, which is the hardest
 * kind of bug to notice. A `:` line is a comment in the SSE grammar.
 */
function sse(conversationId: string): Response {
  const enc = new TextEncoder();
  let sub: Sub;
  let ping: ReturnType<typeof setInterval> | undefined;
  return new Response(
    new ReadableStream({
      start(controller) {
        const send = (chunk: string) => {
          try {
            controller.enqueue(enc.encode(chunk));
          } catch {
            /* the browser went away mid-write */
          }
        };
        send(": connected\n\n");
        sub = { conversationId, send };
        subs.add(sub);
        ping = setInterval(() => send(": ping\n\n"), 15_000);
      },
      cancel() {
        subs.delete(sub);
        if (ping) clearInterval(ping);
      },
    }),
    { headers: { "content-type": "text/event-stream", "cache-control": "no-cache", "access-control-allow-origin": "*" } },
  );
}

// ── the fake disk ──────────────────────────────────────────────────────

/**
 * A repository, as Fountain leaves it after cloning an environment's
 * `repositories` into `/workspace/<name>`.
 *
 * Seeded when the environment is created rather than when a box is built,
 * because that is the moment switchyard names the mount path and it is the
 * only moment the mock is told about it. An empty `/workspace` made the Files
 * panel look broken when it was merely accurate.
 */
function seedClone(root: string): void {
  const name = root.split("/").pop() ?? "repo";
  const files: [string, string][] = [
    ["README.md", `# ${name}\n\nA service that does one thing. This tree is the mock's, not yours.\n\n    bun install\n    bun test\n`],
    ["package.json", `{\n  "name": "${name}",\n  "version": "0.4.2",\n  "type": "module",\n  "scripts": { "test": "bun test" }\n}\n`],
    ["src/index.ts", 'import { route } from "./router";\n\nBun.serve({ port: 8080, fetch: (req) => route(new URL(req.url).pathname)?.(req) ?? new Response("not found", { status: 404 }) });\n'],
    ["src/router.ts", "type Handler = (req: Request) => Response;\n\nconst table: Record<string, Handler> = {\n  \"/healthz\": () => new Response(\"ok\\n\"),\n};\n\nexport function route(path: string): Handler | null {\n  return table[path] ?? null;\n}\n"],
    ["src/lib/format.ts", "export function bytes(n: number): string {\n  const units = [\"B\", \"kB\", \"MB\", \"GB\"];\n  let i = 0;\n  while (n >= 1024 && i < units.length - 1) {\n    n /= 1024;\n    i++;\n  }\n  return `${n.toFixed(i ? 1 : 0)} ${units[i]}`;\n}\n"],
    ["test/router.test.ts", 'import { expect, test } from "bun:test";\nimport { route } from "../src/router";\n\ntest("healthz answers", () => {\n  expect(route("/healthz")).toBeTruthy();\n});\n'],
    [".github/workflows/ci.yml", "name: ci\non: [push, pull_request]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: bun test\n"],
    // A TODO on purpose: "Fix a TODO" is one of the starter chips, and a chip
    // that finds nothing to fix is a chip that makes the machine look broken.
    ["src/lib/window.ts", "// TODO: rounding here is wrong across a DST boundary — it assumes every\n// day is 86400 seconds, which costs an hour twice a year.\nexport function dayOf(ts: number): number {\n  return Math.floor(ts / 86_400);\n}\n"],
  ];
  for (const [rel, body] of files) state.files.set(`${root}/${rel}`, body);
}

/** Copy a directory, the way `git worktree add` populates a fresh checkout. */
function copyTree(from: string, to: string): number {
  let count = 0;
  for (const [path, body] of [...state.files]) {
    if (!path.startsWith(`${from}/`)) continue;
    state.files.set(`${to}/${path.slice(from.length + 1)}`, body);
    count++;
  }
  return count;
}

function removeTree(dir: string): number {
  let count = 0;
  for (const path of [...state.files.keys()]) {
    if (path === dir || path.startsWith(`${dir}/`)) {
      state.files.delete(path);
      count++;
    }
  }
  return count;
}

/**
 * `git diff` in a worktree, as a unified diff.
 *
 * Two files, one modified and one added, because the Changes panel counts
 * added and removed lines per file and parses `new file` — a one-hunk diff
 * would exercise neither. The content is the seeded tree's, so the paths in
 * the panel are paths the Files panel can actually open.
 */
function fakeDiff(): string {
  return [
    "diff --git a/src/lib/window.ts b/src/lib/window.ts",
    "index 8c1f2a4..2ad91b7 100644",
    "--- a/src/lib/window.ts",
    "+++ b/src/lib/window.ts",
    "@@ -1,5 +1,7 @@",
    "-// TODO: rounding here is wrong across a DST boundary — it assumes every",
    "-// day is 86400 seconds, which costs an hour twice a year.",
    "+// Days are counted in the zone the timestamp belongs to, not in fixed",
    "+// 86400-second blocks — a DST boundary is 23 or 25 hours long and the old",
    "+// arithmetic lost an hour twice a year.",
    " export function dayOf(ts: number): number {",
    "-  return Math.floor(ts / 86_400);",
    "+  return Math.floor(zonedSeconds(ts) / 86_400);",
    " }",
    "diff --git a/src/lib/zone.ts b/src/lib/zone.ts",
    "new file mode 100644",
    "index 0000000..b3d7e91",
    "--- /dev/null",
    "+++ b/src/lib/zone.ts",
    "@@ -0,0 +1,6 @@",
    "+/** Seconds since the epoch, shifted into the local zone's own day grid. */",
    "+export function zonedSeconds(ts: number): number {",
    "+  const offset = new Date(ts * 1000).getTimezoneOffset() * 60;",
    "+  return ts - offset;",
    "+}",
    "",
  ].join("\n");
}

// ── the box taking a turn ──────────────────────────────────────────────

const acp = (update: Record<string, unknown>) =>
  JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { update } });

const text = (t: string) => acp({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: t } });
const tool = (id: string, title: string) => acp({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "execute" });
const toolDone = (id: string, out: string) =>
  acp({
    sessionUpdate: "tool_call_update",
    toolCallId: id,
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: out } }],
  });

/**
 * A turn, written into the log over about a second and a half.
 *
 * The shape is Fountain's and the transcript depends on all of it: `turn_id`
 * groups the events, the `stage`/`prompt` event carries what was asked (the
 * UI pulls the person's own words out of there rather than out of the agent's
 * reply), and the `output` events on stream `acp` carry raw ACP ndjson that
 * `blocksForTurn` parses into bubbles and tool chips. Text arrives in deltas
 * because it does on a real runtime, and a transcript that only ever appears
 * all at once hides every streaming bug there is.
 */
async function runTurn(conv: Conv, prompt: string): Promise<void> {
  const turn = `turn-${state.turnSeq++}`;
  const emit = (ev: Record<string, unknown>) => push(conv.id, { turn_id: turn, ...ev });
  const say = async (body: string) => {
    for (const chunk of body.match(/[\s\S]{1,48}/g) ?? []) {
      emit({ kind: "output", stream: "acp", data: text(chunk) });
      await sleep(40);
    }
  };

  if (conv.sandbox_id) state.busy.set(conv.sandbox_id, conv.id);
  conv.status = "running";
  conv.turn_count += 1;
  conv.last_active_at = now();

  const record = {
    id: turn,
    prompt,
    // The app's own turns are marked as such, which is how the transcript can
    // render "Opening this track" differently from something a person typed.
    origin: prompt.startsWith("[switchyard]") ? "app" : "user",
    status: "running",
    inserted_at: now(),
  };
  state.turns.set(conv.id, [...(state.turns.get(conv.id) ?? []), record]);

  emit({ kind: "stage", stage: "prompt", data: prompt });
  emit({ kind: "stage", stage: "turn", state: "started" });
  await sleep(250);

  try {
    await act(prompt, emit, say);
  } finally {
    await sleep(150);
    conv.status = "idle";
    conv.last_active_at = now();
    record.status = "completed";
    emit({ kind: "stage", stage: "turn", state: "completed" });
    if (conv.sandbox_id && state.busy.get(conv.sandbox_id) === conv.id) state.busy.delete(conv.sandbox_id);
  }
}

type Emit = (ev: Record<string, unknown>) => void;
type Say = (body: string) => Promise<void>;

/**
 * What the machine actually does, read out of the prompt.
 *
 * The `[switchyard]` prompts are a contract — `shared/spec.ts` tells the agent
 * exactly what to do and exactly what to reply — so the fake honours it rather
 * than answering in general terms. Cutting a worktree really does create the
 * directory here, which is the whole reason the Files panel works offline;
 * closing one really does take it away, which is how a stale panel would show
 * up in development instead of in production.
 */
async function act(prompt: string, emit: Emit, say: Say): Promise<void> {
  const dir = /\/home\/sprite\/work\/[A-Za-z0-9._-]+/.exec(prompt)?.[0] ?? null;

  if (prompt.startsWith("[switchyard] Open this track") && dir) {
    const repoPath = /The shared clone is (\/\S+?)\./.exec(prompt)?.[1] ?? null;
    const branch = /git worktree add \S+ -b (\S+)/.exec(prompt)?.[1] ?? null;

    if (repoPath) {
      emit({ kind: "output", stream: "acp", data: tool("t1", `cd ${repoPath} && git fetch origin --prune`) });
      await sleep(300);
      emit({ kind: "output", stream: "acp", data: toolDone("t1", "From github.com:mockuser/repo\n * [new branch]  main -> origin/main") });
      emit({ kind: "output", stream: "acp", data: tool("t2", `git worktree add ${dir}${branch ? ` -b ${branch}` : ""}`) });
      await sleep(400);
      const copied = copyTree(repoPath, dir);
      emit({
        kind: "output",
        stream: "acp",
        data: toolDone("t2", `Preparing worktree (new branch '${branch ?? "detached"}')\nHEAD is now at 4f2c1ab ${copied} files`),
      });
    } else {
      emit({ kind: "output", stream: "acp", data: tool("t1", `mkdir -p ${dir}`) });
      await sleep(300);
      emit({ kind: "output", stream: "acp", data: toolDone("t1", "") });
      state.files.set(`${dir}/.keep`, "");
    }
    state.worktrees.set(dir, { branch, repoPath });
    // One line, exactly as the contract asks: the app parses nothing out of it,
    // but a person reads it as the machine's receipt for the directory.
    await say(branch ? `${dir} on ${branch}` : dir);
    return;
  }

  if (prompt.startsWith("[switchyard] Close this track") && dir) {
    const removed = removeTree(dir);
    emit({ kind: "output", stream: "acp", data: tool("t1", `git worktree remove ${dir}`) });
    await sleep(300);
    emit({ kind: "output", stream: "acp", data: toolDone("t1", "") });
    state.worktrees.delete(dir);
    await say(`Removed ${dir} (${removed} files) and pruned the worktree record. The branch is untouched.`);
    return;
  }

  if (prompt.startsWith("[switchyard] Report what is on this machine")) {
    const worktrees = [...state.worktrees].map(([path, w]) => ({ path, branch: w.branch, dirty: false }));
    const repos = [...new Set([...state.worktrees.values()].map((w) => w.repoPath).filter((p): p is string => !!p))];
    emit({ kind: "output", stream: "acp", data: tool("t1", `ls -1 ${WORKSPACE_ROOT} && git worktree list`) });
    await sleep(300);
    emit({ kind: "output", stream: "acp", data: toolDone("t1", worktrees.map((w) => `${w.path}  ${w.branch ?? "(detached)"}`).join("\n")) });
    state.files.set(RECEIPT_PATH, JSON.stringify({ surveyed_at: now(), repos, worktrees }, null, 2));
    await say(worktrees.map((w) => `${w.path} ${w.branch ?? "(no branch)"}`).join("\n") || "No worktrees on this machine.");
    return;
  }

  // An ordinary turn from a person. It runs a command and answers from inside
  // the track's own directory, because saying so is the one thing the system
  // prompt spends its whole length on and a fake that wandered elsewhere would
  // be modelling the failure rather than the behaviour.
  const home = [...state.worktrees.keys()].find((d) => hasFilesUnder(d)) ?? WORK_ROOT;
  emit({ kind: "output", stream: "acp", data: tool("x1", `cd ${home} && rg -n "TODO|FIXME"`) });
  await sleep(400);
  emit({ kind: "output", stream: "acp", data: toolDone("x1", "src/lib/window.ts:1:// TODO: rounding here is wrong across a DST boundary") });
  await say(
    `(mock) I am in ${home} and I read: ${prompt.trim().split("\n")[0]?.slice(0, 120)}\n\n` +
      "There is one TODO worth doing here — `dayOf` in `src/lib/window.ts` divides by 86400, which is an hour short twice a year. Say the word and I will fix it on this track's branch.",
  );
}

function hasFilesUnder(dir: string): boolean {
  for (const path of state.files.keys()) if (path.startsWith(`${dir}/`)) return true;
  return false;
}

/**
 * Accept a prompt, or refuse it the way Fountain does.
 *
 * The box runs one turn at a time across every conversation on it, and that is
 * not an implementation detail switchyard can paper over — it is the fact the
 * whole "one machine, several tracks" design is built around. A second track
 * prompted mid-turn gets 409 `sandbox_at_capacity`; a second prompt to the
 * *same* track queues behind its own turn, which is what a person typing twice
 * in a row expects.
 */
function accept(conv: Conv, prompt: string): { error: string } | null {
  const holder = conv.sandbox_id ? state.busy.get(conv.sandbox_id) : undefined;
  if (holder && holder !== conv.id) return { error: "sandbox_at_capacity" };
  const tail = state.queues.get(conv.id) ?? Promise.resolve();
  const next = tail.then(() => runTurn(conv, prompt)).catch((err: unknown) => {
    console.error("mock: turn blew up:", err);
  });
  state.queues.set(conv.id, next);
  return null;
}

// ── small helpers ──────────────────────────────────────────────────────

function json(data: unknown, status = 200): Response {
  return Response.json(data, { status, headers: { "access-control-allow-origin": "*" } });
}

function html(body: string, status = 200): Response {
  return new Response(body, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}

function secretsFor(parent: string, id: string): Map<string, string> {
  const key = `${parent}:${id}`;
  const existing = state.secrets.get(key);
  if (existing) return existing;
  const made = new Map<string, string>();
  state.secrets.set(key, made);
  return made;
}

// ── Fountain ───────────────────────────────────────────────────────────

async function fountain(req: Request, url: URL): Promise<Response | null> {
  const p = url.pathname;
  const method = req.method;
  // The bearer token is read and ignored on purpose: switchyard holds exactly
  // one Fountain key for everybody, and rejecting a wrong one here would only
  // ever catch a typo in the dev command line.
  const body = method === "POST" || method === "PUT" ? ((await req.json().catch(() => ({}))) as Record<string, unknown>) : {};

  if (p === "/api/auth/me") return json({ data: { id: "u-mock", email: "switchyard@example.com" } });

  if (p === "/api/catalog") {
    return json({
      data: {
        runtimes: ["claude"],
        models: { claude: ["claude-opus-5", "claude-sonnet-5"] },
        package_managers: ["apt", "npm"],
        mcp_servers: [],
      },
    });
  }

  // ── the three records a project is ───────────────────────────────────

  for (const [collection, list] of [
    ["environments", state.environments],
    ["vaults", state.vaults],
    ["agents", state.agents],
  ] as const) {
    if (p === `/api/${collection}`) {
      if (method === "GET") return json({ data: list });
      if (method === "POST") {
        const record = { id: `${collection[0]}${list.length + 1}-${Math.random().toString(36).slice(2, 8)}`, ...body };
        list.push(record);
        // The clone lands on disk when the environment names it, which is the
        // only moment this mock is told a mount path at all.
        if (collection === "environments") {
          for (const repo of (body.repositories as { mount_path?: string }[] | undefined) ?? []) {
            if (repo.mount_path) seedClone(repo.mount_path);
          }
        }
        return json({ data: record });
      }
    }
    const id = new RegExp(`^/api/${collection}/([^/]+)$`).exec(p)?.[1];
    if (id) {
      const record = list.find((r) => r.id === id);
      if (!record) return json({ error: "not_found" }, 404);
      if (method === "DELETE") {
        const i = list.indexOf(record);
        list.splice(i, 1);
        state.secrets.delete(`${collection}:${id}`);
        // Retiring the agent is what costs the disk — the identity moved, so
        // the box built for it is gone. Reproducing that is the point of
        // "rebuild" having a confirmation dialog in front of it.
        if (collection === "agents") state.boxes.delete(id);
        return new Response(null, { status: 204 });
      }
      if (method === "PUT") Object.assign(record, body);
      return json({ data: record });
    }
  }

  const secretList = /^\/api\/(environments|vaults)\/([^/]+)\/secrets$/.exec(p);
  if (secretList) {
    const bag = secretsFor(secretList[1]!, secretList[2]!);
    if (method === "POST") {
      // A write is `POST /secrets` with the key *in the body*, and it
      // overwrites — so rotating the clone token is one call rather than a
      // create that 409s and an update that 404s on the first rotation.
      const b = body as { key?: unknown; value?: unknown };
      const key = String(b.key ?? "");
      if (!key) return json({ error: "validation_failed", errors: { key: ["can't be blank"] } }, 422);
      bag.set(key, String(b.value ?? ""));
      return json({ data: { key, updated_at: now() } });
    }
    // Keys, never values. Fountain does not hand a secret back once it is in,
    // and a mock that did would let a panel grow a "reveal" button that could
    // never work against the real thing.
    return json({ data: [...bag.keys()].map((key) => ({ key, updated_at: now() })) });
  }
  const secretOne = /^\/api\/(environments|vaults)\/([^/]+)\/secrets\/([^/]+)$/.exec(p);
  if (secretOne) {
    const bag = secretsFor(secretOne[1]!, secretOne[2]!);
    const key = decodeURIComponent(secretOne[3]!);
    if (method === "PUT") bag.set(key, String((body as { value?: unknown }).value ?? ""));
    if (method === "DELETE") bag.delete(key);
    return json({ data: { key } });
  }

  // ── conversations ────────────────────────────────────────────────────

  if (p === "/api/conversations" && method === "GET") {
    const agentId = url.searchParams.get("agent_id");
    const mine = agentId ? state.conversations.filter((c) => c.agent_id === agentId) : state.conversations;
    return json({ data: mine.map(withBox) });
  }

  if (p === "/api/conversations" && method === "POST") {
    const b = body as Record<string, string | undefined>;
    const agentId = b.agent_id;
    if (!agentId) return json({ error: "validation_failed", errors: { agent_id: ["can't be blank"] } }, 422);

    let box = state.boxes.get(agentId);
    if (b.sandbox_id) {
      // The rule that costs the most to get wrong, so the fake enforces it.
      // A disk is built for (agent, environment, vault) *by id*, and naming
      // only some of them asks for a different identity — one with no
      // environment and no vault. Fountain answers 422; switchyard's bug was
      // that nothing local ever did, so the attach silently built a second
      // machine and the first one's worktrees vanished from the UI.
      if (!box || box.id !== b.sandbox_id) return json({ error: "sandbox_not_found" }, 404);
      const wanted = { environment_id: b.environment_id ?? null, vault_id: b.vault_id ?? null };
      if ((box.environment_id ?? null) !== wanted.environment_id || (box.vault_id ?? null) !== wanted.vault_id) {
        return json(
          { error: "sandbox_identity_mismatch", message: "That machine was built for a different agent, environment or vault." },
          422,
        );
      }
    } else if (!box) {
      box = {
        id: `sb-${agentId}`,
        sprite_name: `switchyard-${Math.random().toString(36).slice(2, 8)}`,
        status: "ready",
        provider: "mock",
        mode: "persistent",
        agent_id: agentId,
        environment_id: b.environment_id ?? null,
        vault_id: b.vault_id ?? null,
        url: null,
      };
      state.boxes.set(agentId, box);
    }

    const agent = state.agents.find((a) => a.id === agentId) as { runtime?: string } | undefined;
    const conv: Conv = {
      id: `c${state.conversations.length + 1}-${Math.random().toString(36).slice(2, 8)}`,
      title: b.title ?? null,
      sandbox_id: box!.id,
      agent_id: agentId,
      vault_id: b.vault_id ?? null,
      environment_id: b.environment_id ?? null,
      runtime: agent?.runtime ?? "claude",
      status: "pending",
      channel_id: b.channel_id ?? null,
      turn_count: 0,
      last_active_at: null,
      inserted_at: now(),
    };
    state.conversations.push(conv);
    // A prompt sent with the launch is the first turn. Switchyard sends the
    // opening turn this way on the launch that *provisions* the box and
    // separately on an attach, so a mock that ignored it would leave every
    // brand-new project's first track sitting in `opening` forever.
    const first = typeof b.prompt === "string" ? b.prompt : "";
    if (first.trim() && accept(conv, first)) {
      console.warn(`mock: the launch prompt for ${conv.id} arrived while ${box!.id} was mid-turn and was dropped`);
    }
    return json({ data: withBox(conv) });
  }

  const convPrompt = /^\/api\/conversations\/([^/]+)\/prompts$/.exec(p);
  if (convPrompt) {
    const conv = state.conversations.find((c) => c.id === convPrompt[1]);
    if (!conv) return json({ error: "not_found" }, 404);
    const refused = accept(conv, String((body as { prompt?: unknown }).prompt ?? ""));
    if (refused) return json(refused, 409);
    return json({ status: "accepted" });
  }

  const convStream = /^\/api\/conversations\/([^/]+)\/stream$/.exec(p);
  if (convStream) return sse(convStream[1]!);

  const convEvents = /^\/api\/conversations\/([^/]+)\/events$/.exec(p);
  if (convEvents) {
    const all = state.events.get(convEvents[1]!) ?? [];
    // Oldest first, capped the way Fountain caps it. The tail is what a track
    // that has been worked in for an hour needs — taking the *head* would show
    // a scrollback that looks complete and is a hundred turns stale.
    const limit = Math.min(Number(url.searchParams.get("limit") ?? 100) || 100, 1000);
    return json({ data: all.slice(-limit), meta: { has_more: all.length > limit, next_cursor: null } });
  }

  const convTurns = /^\/api\/conversations\/([^/]+)\/turns$/.exec(p);
  if (convTurns) return json({ data: state.turns.get(convTurns[1]!) ?? [] });

  const convAction = /^\/api\/conversations\/([^/]+)\/(interrupt|terminate)$/.exec(p);
  if (convAction) {
    const conv = state.conversations.find((c) => c.id === convAction[1]);
    if (conv) {
      conv.status = convAction[2] === "terminate" ? "terminated" : "idle";
      if (conv.sandbox_id && state.busy.get(conv.sandbox_id) === conv.id) state.busy.delete(conv.sandbox_id);
    }
    return json({ status: "ok" });
  }

  const convOne = /^\/api\/conversations\/([^/]+)$/.exec(p);
  if (convOne) {
    const conv = state.conversations.find((c) => c.id === convOne[1]);
    return conv ? json({ data: withBox(conv) }) : json({ error: "not_found" }, 404);
  }

  // ── the box, read-only ───────────────────────────────────────────────

  const sbFiles = /^\/api\/sandboxes\/([^/]+)\/files$/.exec(p);
  if (sbFiles) {
    const dir = (url.searchParams.get("path") ?? "/").replace(/\/+$/, "");
    const seen = new Map<string, { name: string; type: string; size: number | null }>();
    for (const [path, content] of state.files) {
      if (!path.startsWith(`${dir}/`)) continue;
      const rest = path.slice(dir.length + 1);
      const slash = rest.indexOf("/");
      const name = slash === -1 ? rest : rest.slice(0, slash);
      // "directory", which is Fountain's word. Saying "dir" here is what let a
      // wrong assumption in a client survive every local test and then render
      // every folder as an unopenable file.
      seen.set(name, slash === -1 ? { name, type: "file", size: content.length } : { name, type: "directory", size: null });
    }
    return json({ data: { path: dir || "/", entries: [...seen.values()], truncated: false } });
  }

  const sbFile = /^\/api\/sandboxes\/([^/]+)\/file$/.exec(p);
  if (sbFile) {
    const path = url.searchParams.get("path") ?? "";
    const content = state.files.get(path);
    if (content === undefined) return json({ error: "not_found" }, 404);
    return json({ data: { path, size: content.length, truncated: false, encoding: "utf8", content } });
  }

  const sbDiff = /^\/api\/sandboxes\/([^/]+)\/diff$/.exec(p);
  if (sbDiff) {
    const path = url.searchParams.get("path") ?? "";
    const worktree = state.worktrees.get(path);
    return json({
      data: {
        path,
        repo_root: path,
        staged: false,
        ref: worktree?.branch ?? null,
        // Nothing to show until the worktree exists — a track whose opening
        // turn has not landed yet has no changes, and inventing some would
        // make the Changes panel lie during the ten seconds that matter most.
        diff: worktree ? fakeDiff() : "",
        truncated: false,
      },
    });
  }

  const sbOne = /^\/api\/sandboxes\/([^/]+)$/.exec(p);
  if (sbOne) {
    const box = [...state.boxes.values()].find((b) => b.id === sbOne[1]);
    return box ? json({ data: box }) : json({ error: "not_found" }, 404);
  }

  return null;
}

const withBox = (c: Conv) => ({ ...c, sandbox: c.sandbox_id ? (state.boxes.get(c.agent_id) ?? null) : null });

// ── GitHub, as fixtures ────────────────────────────────────────────────

const INSTALLATION_ID = 1;
const VIEWER = { id: 1042, login: "mockuser", name: "Mock User", avatar_url: `${BASE}/ghweb/avatar.svg` };

/**
 * Who you can sign in as.
 *
 * One identity offline means multiplayer can only be tested by reading the
 * code. `VIEWER` stays first and owns the repositories, so every existing
 * behaviour is unchanged; the rest exist to be invited, to accept a link, and
 * to have their name appear on a turn.
 */
const PEOPLE = [
  VIEWER,
  { id: 9001, login: "dana", name: "Dana Okonkwo", avatar_url: `${BASE}/ghweb/avatar.svg?dana` },
  { id: 9002, login: "eli", name: "Eli Fischer", avatar_url: `${BASE}/ghweb/avatar.svg?eli` },
];

/** The identity a mock access token names, defaulting to the first. */
function personFor(authorization: string | null): typeof VIEWER {
  const login = (authorization ?? "").split(":")[1]?.trim();
  return PEOPLE.find((x) => x.login === login) ?? VIEWER;
}

interface MockRepo {
  name: string;
  private: boolean;
  language: string | null;
  description: string | null;
  pushed_at: string;
}

/**
 * Six repositories on one installation, because a GitHub App installation
 * belongs to exactly one account and a picker that showed two accounts' repos
 * under one heading would be modelling something that cannot happen.
 *
 * Varied `pushed_at` because the picker sorts by it rather than by name — the
 * person opening it wants what they were just working on — and a fixture where
 * every repo was pushed at the same instant tests nothing.
 */
const REPOS: MockRepo[] = [
  { name: "atlas-api", private: false, language: "TypeScript", description: "The public read API. Bun, SQLite, no framework.", pushed_at: "2026-09-03T18:22:11Z" },
  { name: "ledger", private: true, language: "Go", description: "Double-entry books. Do not touch without a test.", pushed_at: "2026-09-02T09:04:47Z" },
  { name: "switchyard-notes", private: false, language: null, description: "Design notes, mostly markdown.", pushed_at: "2026-08-28T14:51:02Z" },
  { name: "cabinet", private: false, language: "Elixir", description: "Document store behind atlas-api.", pushed_at: "2026-08-19T07:38:20Z" },
  { name: "dotfiles", private: false, language: "Shell", description: null, pushed_at: "2026-06-11T22:10:05Z" },
  { name: "old-site", private: false, language: "HTML", description: "Archived. Kept for the redirects.", pushed_at: "2025-11-30T16:00:00Z" },
];

const repoBody = (name: string) => {
  const r = REPOS.find((x) => x.name === name);
  if (!r) return null;
  return {
    id: REPOS.indexOf(r) + 100,
    full_name: `${VIEWER.login}/${r.name}`,
    name: r.name,
    owner: { login: VIEWER.login, avatar_url: VIEWER.avatar_url },
    private: r.private,
    default_branch: "main",
    description: r.description,
    pushed_at: r.pushed_at,
    language: r.language,
    html_url: `${BASE}/ghweb/${VIEWER.login}/${r.name}`,
  };
};

/**
 * The one branch with a history behind it.
 *
 * `checks()` reads a branch and treats 404 as "never pushed", which is the
 * ordinary state of a brand new track and has its own designed empty state. So
 * unknown branches must 404 — but a mock where *every* branch 404s means the
 * Checks panel can never be seen doing its job. The pull request below is for
 * this ref, so a track started from that PR has a pushed branch, an open PR and
 * three check runs on the first try.
 */
const PUSHED_BRANCH = "mockuser/fix-tz-rounding";
const PUSHED_SHA = "4f2c1abda9e70b5c2c1d8e3f6a7b9c0d1e2f3a4b";

const BRANCHES: { name: string; sha: string }[] = [
  { name: "main", sha: "9a1b2c3d4e5f60718293a4b5c6d7e8f901234567" },
  { name: "release/2026-08", sha: "1122334455667788990011223344556677889900" },
  { name: PUSHED_BRANCH, sha: PUSHED_SHA },
];

let nextPull = 42;
const PULLS: Record<string, unknown>[] = [
  {
    number: 41,
    title: "Count days in the local zone, not in 86400-second blocks",
    user: { login: VIEWER.login },
    head: { ref: PUSHED_BRANCH },
    base: { ref: "main" },
    draft: false,
    updated_at: "2026-09-03T17:02:44Z",
    html_url: `${BASE}/ghweb/${VIEWER.login}/atlas-api/pull/41`,
  },
  {
    number: 38,
    title: "Drop the unused rate limiter",
    user: { login: "cotton" },
    head: { ref: "cotton/drop-limiter" },
    base: { ref: "main" },
    draft: true,
    updated_at: "2026-08-30T11:19:03Z",
    html_url: `${BASE}/ghweb/${VIEWER.login}/atlas-api/pull/38`,
  },
];

const ISSUES = [
  { number: 40, title: "Timestamps drift by an hour after the clocks change", user: { login: "cotton" }, labels: [{ name: "bug" }, { name: "p1" }], updated_at: "2026-09-03T08:12:00Z" },
  { number: 36, title: "Add a /healthz that checks the database too", user: { login: VIEWER.login }, labels: [{ name: "good first issue" }], updated_at: "2026-09-01T19:44:10Z" },
  { number: 31, title: "Document the router table", user: { login: "wren" }, labels: [], updated_at: "2026-08-26T13:05:55Z" },
  { number: 29, title: "bun test is flaky on CI when the cache is cold", user: { login: "wren" }, labels: [{ name: "ci" }, { name: "flaky" }], updated_at: "2026-08-22T06:30:41Z" },
  // A pull request wearing an issue's clothes, because GitHub's issues
  // endpoint returns those too and dropping them is a real filter in
  // `github.ts` that nothing would exercise otherwise.
  { number: 41, title: "Count days in the local zone, not in 86400-second blocks", user: { login: VIEWER.login }, labels: [], updated_at: "2026-09-03T17:02:44Z", pull_request: { url: "…" } },
];

const CHECK_RUNS = [
  { name: "test (bun)", status: "completed", conclusion: "success", html_url: `${BASE}/ghweb/checks/1`, started_at: "2026-09-03T17:03:00Z", completed_at: "2026-09-03T17:04:31Z" },
  { name: "typecheck", status: "completed", conclusion: "failure", html_url: `${BASE}/ghweb/checks/2`, started_at: "2026-09-03T17:03:00Z", completed_at: "2026-09-03T17:03:52Z" },
  { name: "deploy preview", status: "in_progress", conclusion: null, html_url: `${BASE}/ghweb/checks/3`, started_at: "2026-09-03T17:03:00Z", completed_at: null },
];

function githubApi(req: Request, url: URL, body: Record<string, unknown>): Response | null {
  const p = url.pathname.slice("/gh".length);

  // The App's JWT is not verified — this mock has no idea what public key the
  // server signed with and does not need one. What it does need is to answer
  // with an expiry an hour out, because `installationToken` caches until a
  // minute before it and a token that looks already-expired makes every call
  // re-mint.
  const token = /^\/app\/installations\/(\d+)\/access_tokens$/.exec(p);
  if (token) return json({ token: "ghs_mock", expires_at: new Date(Date.now() + 3_600_000).toISOString() });

  if (p === "/user") return json(personFor(req.headers.get("authorization")));

  /**
   * One account by login, which is how somebody with no switchyard account
   * gets invited. A short allowlist rather than "anything is a person":
   * inviting a name that does not exist has to stay reachable offline, because
   * the honest 404 is the more interesting of the two answers.
   */
  const byLogin = /^\/users\/([^/]+)$/.exec(p);
  if (byLogin) {
    const login = decodeURIComponent(byLogin[1]!).toLowerCase();
    const known: Record<string, number> = { octocat: 583231, hubot: 5153, dana: 9001, eli: 9002 };
    if (login === VIEWER.login.toLowerCase()) return json(VIEWER);
    const id = known[login];
    if (id === undefined) return json({ message: "Not Found" }, 404);
    return json({ id, login, name: null, avatar_url: `${BASE}/ghweb/avatar.svg` });
  }

  if (p === "/user/installations") {
    return json({
      total_count: 1,
      installations: [{ id: INSTALLATION_ID, account: { login: VIEWER.login, avatar_url: VIEWER.avatar_url } }],
    });
  }

  const repoList = /^\/user\/installations\/(\d+)\/repositories$/.exec(p);
  if (repoList) {
    if (Number(repoList[1]) !== INSTALLATION_ID) return json({ message: "Not Found" }, 404);
    // Page two is empty, which is what stops `repositories()` looping: it
    // breaks on a short page, and a mock that returned the same full page ten
    // times would hang the picker for ten round trips.
    const page = Number(url.searchParams.get("page") ?? "1");
    const repositories = page > 1 ? [] : REPOS.map((r) => repoBody(r.name));
    return json({ total_count: REPOS.length, repositories });
  }

  const repo = /^\/repos\/([^/]+)\/([^/]+)(\/.*)?$/.exec(p);
  if (repo) {
    const found = repoBody(repo[2]!);
    if (!found) return json({ message: "Not Found" }, 404);
    const rest = repo[3] ?? "";

    if (!rest) return json(found);
    if (rest === "/branches") return json(BRANCHES.map((b) => ({ name: b.name, commit: { sha: b.sha } })));

    const branch = /^\/branches\/(.+)$/.exec(rest);
    if (branch) {
      const name = decodeURIComponent(branch[1]!);
      const match = BRANCHES.find((b) => b.name === name);
      // 404 is the answer for a branch nobody has pushed, and it is a
      // first-class one: `checks()` turns it into `pushed: false` and the panel
      // says so rather than showing an empty list that reads as a failure.
      if (!match) return json({ message: "Branch not found" }, 404);
      return json({ name: match.name, commit: { sha: match.sha } });
    }

    if (rest === "/pulls") {
      if (req.method === "POST") {
        const input = body as { head?: string; base?: string; title?: string; draft?: boolean };
        const made = {
          number: nextPull++,
          title: input.title ?? "Untitled",
          user: { login: VIEWER.login },
          head: { ref: input.head ?? "unknown" },
          base: { ref: input.base ?? "main" },
          draft: input.draft !== false,
          updated_at: now(),
          html_url: `${BASE}/ghweb/${found.full_name}/pull/${nextPull - 1}`,
        };
        PULLS.unshift(made);
        return json(made, 201);
      }
      // `checks()` asks with `head=owner:ref` to find the PR for one branch;
      // the picker asks with no head at all and wants them all.
      const head = url.searchParams.get("head");
      const ref = head?.split(":")[1];
      return json(ref ? PULLS.filter((x) => (x.head as { ref: string }).ref === ref) : PULLS);
    }

    if (rest === "/issues") return json(ISSUES);

    const checks = /^\/commits\/([^/]+)\/check-runs$/.exec(rest);
    if (checks) return json({ total_count: CHECK_RUNS.length, check_runs: checks[1] === PUSHED_SHA ? CHECK_RUNS : [] });
  }

  return null;
}

// ── GitHub, as a browser meets it ──────────────────────────────────────

const PAGE = (title: string, inner: string) => html(`<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #0d1117; color: #e6edf3;
         font: 14px/1.5 ui-sans-serif, -apple-system, "Segoe UI", sans-serif; }
  .card { width: min(92vw, 380px); padding: 28px; border: 1px solid #30363d; border-radius: 12px; background: #161b22; }
  h1 { margin: 0 0 4px; font-size: 17px; }
  p { margin: 0 0 20px; color: #8b949e; }
  a.btn { display: block; padding: 10px 16px; border-radius: 8px; background: #238636; color: #fff;
          text-align: center; text-decoration: none; font-weight: 600; }
  code { color: #8b949e; font-size: 12px; }
</style>
<div class="card">${inner}</div>`);

function githubWeb(req: Request, url: URL, webBody: Record<string, unknown> = {}): Response {
  const p = url.pathname.slice("/ghweb".length);

  if (p === "/avatar.svg") {
    const who = url.search.replace(/^\?/, "") || VIEWER.login;
    const letter = who.slice(0, 1).toUpperCase();
    const hue = [...who].reduce((a, c) => a + c.charCodeAt(0), 0) % 360;
    return new Response(
      `<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80" viewBox="0 0 80 80"><rect width="80" height="80" rx="40" fill="hsl(${hue} 62% 46%)"/><text x="40" y="52" font-family="ui-sans-serif,sans-serif" font-size="34" font-weight="600" fill="#fff" text-anchor="middle">${letter}</text></svg>`,
      { headers: { "content-type": "image/svg+xml", "cache-control": "max-age=3600" } },
    );
  }

  /**
   * The authorize page, and the reason this mock has a web half at all.
   *
   * A real OAuth round trip needs a browser and a session at github.com, which
   * is exactly what an offline developer does not have. So this is a page with
   * one button on it, and pressing it does what GitHub would: send the browser
   * back to `redirect_uri` with a code and the state untouched. That single
   * page is the difference between an app you can use offline and a sign-in
   * screen you can only look at.
   */
  if (p === "/login/oauth/authorize") {
    const redirect = url.searchParams.get("redirect_uri") ?? `${APP_URL}/api/auth/callback`;
    const state = url.searchParams.get("state") ?? "";
    // A button per identity, because everything about sharing a track needs a
    // second person to be worth looking at, and one identity offline means
    // testing multiplayer by reading the code. The chosen login rides back on
    // the `code`, which is opaque to the server and is exactly where a real
    // authorization code carries who authorized it.
    const buttons = PEOPLE.map(
      (who) =>
        `<a class="btn" style="margin-bottom:8px" href="${redirect}${redirect.includes("?") ? "&" : "?"}${new URLSearchParams({ code: `mockcode:${who.login}`, state })}">Sign in as @${who.login}</a>`,
    ).join("");
    return PAGE(
      "Authorize switchyard",
      `<h1>Authorize switchyard</h1>
       <p>This is the mock GitHub. Nothing here is real and no network was involved.</p>
       ${buttons}
       <p style="margin:16px 0 0"><code>${url.searchParams.get("scope") ?? "read:user"}</code></p>`,
    );
  }

  if (p === "/login/oauth/access_token") {
    // The login rides on the code and out again on the token, so nothing here
    // has to remember who was mid-sign-in — which matters, because two browsers
    // signing in as two people at once is the case this exists for.
    const login = (webBody.code ? String(webBody.code) : "").split(":")[1] ?? VIEWER.login;
    return json({ access_token: `gho_mock:${login}`, token_type: "bearer", scope: "read:user" });
  }

  /**
   * Installing the App.
   *
   * The real page carries no `redirect_uri` — GitHub sends the browser to the
   * callback registered on the App — so the fake has to be told where that is,
   * and `SWITCHYARD_URL` is that. It lands with `installation_id` and no
   * `code`, which is the branch in `auth.callback` that means "already signed
   * in, just granted access".
   */
  const install = /^\/apps\/([^/]+)\/installations\/new$/.exec(p);
  if (install) {
    const state = url.searchParams.get("state");
    const back = `${APP_URL}/api/auth/callback?${new URLSearchParams({
      installation_id: String(INSTALLATION_ID),
      setup_action: "install",
      ...(state ? { state } : {}),
    })}`;
    return PAGE(
      `Install ${install[1]}`,
      `<h1>Install ${install[1]}</h1>
       <p>Grant it the ${REPOS.length} repositories on <strong>@${VIEWER.login}</strong>. The mock has no other accounts.</p>
       <a class="btn" href="${back}">Install &amp; Authorize</a>
       <script>location.replace(${JSON.stringify(back)});</script>`,
    );
  }

  // Everything else under the web host is a link out of the UI — a repository,
  // a pull request, a check run. A stub page beats a dead link, and it says
  // where it would have gone.
  void req;
  return PAGE("github.com (mock)", `<h1>${p}</h1><p>On the real GitHub this is a page. Here it is a reminder that it is not.</p>`);
}

// ── the port ───────────────────────────────────────────────────────────

Bun.serve({
  port: PORT,
  // A track's transcript stream stays open as long as its tab is; the default
  // idle timeout would cut every one of them at two minutes.
  idleTimeout: 0,
  async fetch(req) {
    const url = new URL(req.url);
    const p = url.pathname;
    if (req.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "access-control-allow-origin": "*",
          "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
          "access-control-allow-headers": "authorization,content-type,accept,user-agent,x-github-api-version",
        },
      });
    }

    let res: Response | null = null;
    if (p.startsWith("/api/")) res = await fountain(req, url);
    else if (p.startsWith("/gh/")) {
      const body = req.method === "POST" ? ((await req.json().catch(() => ({}))) as Record<string, unknown>) : {};
      res = githubApi(req, url, body);
    } else if (p.startsWith("/ghweb/") || p === "/ghweb") {
      // The token exchange is the one POST on the web host, and its body
      // carries the code that names who signed in.
      const body = req.method === "POST" ? ((await req.json().catch(() => ({}))) as Record<string, unknown>) : {};
      res = githubWeb(req, url, body);
    }

    if (res) return res;

    // Loud on purpose. A route the app calls and the fake does not serve is a
    // gap in the fake, and a quiet 404 here is indistinguishable from a screen
    // that is simply empty — which is how three real bugs in this suite hid.
    console.warn(`mock: no route for ${req.method} ${p}`);
    return json({ error: "not_found", message: `mock has no route for ${req.method} ${p}` }, 404);
  },
});

// ── the key, and the command line ──────────────────────────────────────

/**
 * A throwaway App key.
 *
 * Kept on disk rather than regenerated each start so that a server launched
 * with `$(cat …)` from a previous shell keeps working across a restart of the
 * mock. Nothing verifies the signature — the fake `access_tokens` route hands
 * out a token for any JWT — but `appJwt()` really does sign, so the PEM has to
 * be a real one or the server falls over before it ever gets here.
 */
const keyPath = join(import.meta.dir, "dev-key.pem");
if (!existsSync(keyPath)) {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  writeFileSync(keyPath, privateKey.export({ type: "pkcs8", format: "pem" }).toString(), { mode: 0o600 });
}

console.log(
  [
    `mock fountain + github on ${BASE}`,
    `  fountain   ${BASE}/api`,
    `  github api ${BASE}/gh`,
    `  github web ${BASE}/ghweb   (sign in as @${VIEWER.login}, ${REPOS.length} repositories)`,
    `  app key    ${keyPath}`,
    "",
    "Run the server against it, from apps/switchyard:",
    "",
    `  FOUNTAIN_URL=${BASE} FOUNTAIN_API_KEY=ftn_mock \\`,
    `  GITHUB_API_URL=${BASE}/gh GITHUB_WEB_URL=${BASE}/ghweb \\`,
    "  GITHUB_APP_ID=1 GITHUB_APP_SLUG=switchyard-mock \\",
    "  GITHUB_CLIENT_ID=Iv1.mock GITHUB_CLIENT_SECRET=mocksecret \\",
    '  GITHUB_PRIVATE_KEY="$(cat mock/dev-key.pem)" \\',
    `  PUBLIC_URL=${APP_URL} STATIC_DIR= DATA_DIR=./data \\`,
    "  bun --watch server/index.ts",
    "",
    `  bun run dev        # the SPA on ${APP_URL}, proxying /api to :8081`,
    "",
  ].join("\n"),
);
