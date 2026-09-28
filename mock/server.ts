/**
 * A tiny mock of *both* halves of ravix's world, in one process.
 *
 * Every other app in this suite needs a fake Fountain to be developed offline.
 * Ravix needs a fake GitHub as well, and not as a convenience: sign-in is
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
import { WORKSPACE_ROOT, WORK_ROOT, RECEIPT_PATH, parseChannel } from "../shared/contract";
let updateMockPreview = (_workdir: string): void => {};

const PORT = Number(process.env.MOCK_PORT || 8793);
const BASE = `http://localhost:${PORT}`;

/**
 * Where ravix is, as a *browser* reaches it — which is Vite in dev, not
 * the API server. The install flow needs it because GitHub's own
 * `/apps/:slug/installations/new` carries no `redirect_uri`: the real one
 * redirects to the callback registered on the App, and the fake has to be told
 * the same thing.
 */
const APP_URL = (process.env.RAVIX_URL ?? "http://localhost:5183").replace(/\/+$/, "");

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
  /** The conversation's own model (Fountain ADR 0061); null follows the agent's. */
  model: string | null;
  turn_generation: number;
  inference_credential_id: string | null;
  inference_revision: number;
}

interface Disk {
  files: Map<string, string>;
  worktrees: Map<string, { branch: string | null; repoPath: string | null }>;
}

interface Box extends Disk {
  user_id: string;
  guest_agent_id: string | null;
  runtime: string;
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
  /**
   * Inference credential sets: one per Ravix person, plus the empty default
   * Ravix reserves. `providers` is which slots hold something; the values are
   * not kept at all, because nothing may ever read one back.
   */
  credentialSets: [] as {
    id: string;
    name: string;
    is_default: boolean;
    revision: number;
    providers: string[];
    chatgpt_grant_id: string | null;
  }[],
  /**
   * ChatGPT subscriptions (Fountain's grants) and the device-code sign-ins
   * that link them. A sign-in here is approved by being read: the third
   * poll of a pending attempt completes it, which is as much of ChatGPT as
   * the walkthrough needs. A name containing "refused" is a sign-in ChatGPT
   * turns down, so that the refusal can be seen without a real account.
   */
  chatgptGrants: [] as { id: string; name: string; status: string; plan_type: string; account_email: string }[],
  /**
   * Which ChatGPT account a sign-in is signing in as.
   *
   * Fountain refuses a second link *of the same ChatGPT account*
   * (`account_already_linked`), so the mock needs an account identity to
   * refuse against. Each sign-in is its own by default, keyed by the name the
   * link carries (`ravix:<user id>`), because several people linking here is
   * ordinary and must not collide: a spec that signs in three users and links
   * each would otherwise be refused for the second, and which spec hits that
   * would depend on which shard it landed in.
   *
   * The conflict is opt-in. `POST /__browser/chatgpt-account {"identity": ...}`
   * pins every later sign-in to one account, which is what makes two Ravix
   * logins fight over one ChatGPT account on purpose; `null` restores the
   * per-person default.
   */
  chatgptIdentity: null as string | null,
  chatgptAttempts: [] as {
    id: string;
    kind: "link" | "reconnect";
    name: string | null;
    grant_id: string | null;
    state: string;
    polls: number;
    result_grant_id: string | null;
    failure: { reason: string; grant_id?: string | null; grant?: string | null } | null;
    expires_at: string;
  }[],
  conversations: [] as Conv[],
  /** Sandboxes are keyed by id; home identity includes the per-track vault. */
  boxes: new Map<string, Box>(),
  events: new Map<string, Record<string, unknown>[]>(),
  /**
   * The turn records, which are a second list beside the log and not a view of
   * it. Fountain keeps the prompt on the turn and serves it on the log only
   * when asked (`?prompts=true`), on the turn's opening event; the events
   * handler below reads it from here to do the same.
   */
  turns: new Map<string, Record<string, unknown>[]>(),
  /** Synchronously reserved turns, partitioned by sandbox and runtime. */
  busy: new Map<string, Set<string>>(),
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
 * One newest-first page, as Fountain's `_unsafe_list_log_events_backward`
 * builds it: the newest `limit` events, then, with `whole_turns`, down to
 * the first event of every turn on the page (and of every turn that brings
 * in), at most 5,000 events.
 */
function backwardPage(ascending: Record<string, unknown>[], limit: number, wholeTurns: boolean) {
  const rows = [...ascending].reverse();
  if (rows.length <= limit) return { page: rows, hasMore: false, turnSplit: false };
  let page = rows.slice(0, limit);
  if (!wholeTurns) return { page, hasMore: true, turnSplit: false };
  const firstOf = new Map<unknown, number>();
  for (const ev of ascending) if (ev.turn_id != null && !firstOf.has(ev.turn_id)) firstOf.set(ev.turn_id, ev.id as number);
  let floor = page[page.length - 1]!.id as number;
  let fresh = page;
  for (;;) {
    const starts = [...new Set(fresh.map((ev) => ev.turn_id).filter((t) => t != null))].map((t) => firstOf.get(t)!);
    const start = starts.length ? Math.min(...starts) : Infinity;
    if (!(start < floor)) break;
    const room = 5000 - page.length;
    const extra = rows.filter((ev) => (ev.id as number) >= start && (ev.id as number) < floor);
    if (extra.length > room) return { page: page.concat(extra.slice(0, room)), hasMore: true, turnSplit: true };
    page = page.concat(extra);
    fresh = extra;
    floor = start;
  }
  return { page, hasMore: rows.some((ev) => (ev.id as number) < floor), turnSplit: false };
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
 * Each newly provisioned sandbox gets its own copy from the environment.
 * Reusing a home identity preserves that disk; a different vault does not.
 */
function seedClone(disk: Disk, root: string): void {
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
  for (const [rel, body] of files) disk.files.set(`${root}/${rel}`, body);
}

/** Copy a directory, the way `git worktree add` populates a fresh checkout. */
function copyTree(disk: Disk, from: string, to: string): number {
  let count = 0;
  for (const [path, body] of [...disk.files]) {
    if (!path.startsWith(`${from}/`)) continue;
    disk.files.set(`${to}/${path.slice(from.length + 1)}`, body);
    count++;
  }
  return count;
}

function removeTree(disk: Disk, dir: string): number {
  let count = 0;
  for (const path of [...disk.files.keys()]) {
    if (path === dir || path.startsWith(`${dir}/`)) {
      disk.files.delete(path);
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
const plan = (entries: [string, string][]) =>
  acp({ sessionUpdate: "plan", entries: entries.map(([content, status]) => ({ content, status, priority: "medium" })) });
const thought = (t: string) => acp({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: t } });
// A shell call as the Claude adapter reports one: titled with the command, and
// the command again among the raw arguments beside the directory it ran in.
const tool = (id: string, title: string, cwd?: string) =>
  acp({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "execute", rawInput: { command: title, ...(cwd ? { cwd } : {}) } });
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
 * groups the events, the `turn`/`started` event is where the events feed
 * serves what was asked (`?blocks=true&prompts=true`; the stream never does),
 * and the `output` events on stream `acp` carry raw ACP ndjson that
 * `Ravix.Tracks.Transcript` parses into text, tools and plans. Text arrives in deltas
 * because it does on a real runtime, and a transcript that only ever appears
 * all at once hides every streaming bug there is.
 */
type PromptImage = { data: string; media_type: string };

async function runTurn(conv: Conv, prompt: string, clientRequestId: string | null, images: PromptImage[], attaching = false): Promise<void> {
  const generation = conv.turn_generation;
  const disk = state.boxes.get(conv.sandbox_id!);
  if (!disk) return;
  const alive = () => conv.turn_generation === generation && state.boxes.has(disk.id);
  const pause = async (ms: number) => {
    await sleep(ms);
    if (!alive()) throw cancelledTurn;
  };
  if (attaching) await pause(250);
  const turn = `turn-${state.turnSeq++}`;
  const emit = (ev: Record<string, unknown>) => { if (alive()) push(conv.id, { turn_id: turn, ...ev }); };
  const say = async (body: string) => {
    for (const chunk of body.match(/[\s\S]{1,48}/g) ?? []) {
      emit({ kind: "output", stream: "acp", data: text(chunk) });
      await pause(40);
    }
  };

  conv.status = "running";
  conv.turn_count += 1;
  conv.last_active_at = now();

  const record = {
    id: turn,
    prompt,
    // Fountain's `origin` is `user` for anything sent over the API, Ravix's
    // own `[ravix]` turns included; only a turn Fountain started itself is
    // `autonomous`, and those get no prompt on the feed.
    origin: "user",
    status: attaching ? "pending" : "running",
    inserted_at: now(),
    // The sender's name for the prompt, copied back so it can tell which
    // turn was its own (the prompt queue sends its row id).
    client_request_id: clientRequestId,
    image_count: images.length,
    images,
  };
  state.turns.set(conv.id, [...(state.turns.get(conv.id) ?? []), record]);

  if (attaching) {
    await pause(100);
    record.status = "running";
  }
  emit({ kind: "stage", stage: "turn", state: "started" });
  try {
    await pause(250);
    await act(prompt, emit, say, conv, disk, pause);
    await pause(150);
  } catch (error) {
    if (error !== cancelledTurn) throw error;
  } finally {
    if (alive()) {
      conv.status = "idle";
      conv.last_active_at = now();
      record.status = "completed";
      emit({ kind: "stage", stage: "turn", state: "completed" });
      releaseTurn(conv);
    }
  }
}

type Emit = (ev: Record<string, unknown>) => void;
type Say = (body: string) => Promise<void>;

/**
 * What the machine actually does, read out of the prompt.
 *
 * The `[ravix]` prompts are a contract — `Ravix.Spec` tells the agent
 * exactly what to do and exactly what to reply — so the fake honours it rather
 * than answering in general terms. Cutting a worktree really does create the
 * directory here, which is the whole reason the Files panel works offline;
 * closing one really does take it away, which is how a stale panel would show
 * up in development instead of in production.
 */
async function act(prompt: string, emit: Emit, say: Say, conv: Conv, disk: Disk, pause: (ms: number) => Promise<void>): Promise<void> {
  if (prompt.endsWith("Demonstrate a recovered tool error")) {
    emit({ kind: "output", stream: "acp", data: tool("failed-test", "mix test") });
    emit({ kind: "output", stream: "acp", data: acp({
      sessionUpdate: "tool_call_update", toolCallId: "failed-test", status: "failed",
      content: [{ type: "content", content: { type: "text", text: "1 test failed" } }],
    }) });
    await say("I fixed the test and will run it again.");
    emit({ kind: "output", stream: "acp", data: tool("retry-test", "mix test") });
    emit({ kind: "output", stream: "acp", data: toolDone("retry-test", "All tests passed") });
    await say("The fix is complete.");
    return;
  }

  const dir = /\/home\/sprite\/work\/[A-Za-z0-9._-]+/.exec(prompt)?.[0] ?? null;

  if (prompt.startsWith("[ravix] Open this track") && dir) {
    const dedicated = prompt.includes("ordinary clone, with no worktrees");
    const repoPath = /The shared clone is (\/\S+?)\./.exec(prompt)?.[1] ?? null;
    const branch = /git worktree add \S+ -b (\S+)/.exec(prompt)?.[1] ?? null;

    if (dedicated) {
      emit({ kind: "output", stream: "acp", data: tool("t1", `git clone repository ${dir}`) });
      await pause(300);
      const source = [...disk.files.keys()].find(path => path.endsWith("/README.md"));
      if (source) copyTree(disk, source.slice(0, -"/README.md".length), dir);
      disk.files.set(`${dir}/.git/config`, "[core]\nrepositoryformatversion = 0\n");
      emit({ kind: "output", stream: "acp", data: toolDone("t1", "Clone ready") });
    } else if (repoPath) {
      emit({ kind: "output", stream: "acp", data: tool("t1", `cd ${repoPath} && git fetch origin --prune`) });
      await pause(300);
      emit({ kind: "output", stream: "acp", data: toolDone("t1", "From github.com:mockuser/repo\n * [new branch]  main -> origin/main") });
      emit({ kind: "output", stream: "acp", data: tool("t2", `git worktree add ${dir}${branch ? ` -b ${branch}` : ""}`) });
      await pause(400);
      const copied = copyTree(disk, repoPath, dir);
      disk.files.set(`${dir}/.git`, `gitdir: ${repoPath}/.git/worktrees/${dir.split("/").at(-1)}\n`);
      emit({
        kind: "output",
        stream: "acp",
        data: toolDone("t2", `Preparing worktree (new branch '${branch ?? "detached"}')\nHEAD is now at 4f2c1ab ${copied} files`),
      });
    } else {
      emit({ kind: "output", stream: "acp", data: tool("t1", `mkdir -p ${dir}`) });
      await pause(300);
      emit({ kind: "output", stream: "acp", data: toolDone("t1", "") });
      disk.files.set(`${dir}/.keep`, "");
    }
    disk.worktrees.set(dir, { branch, repoPath });
    // One line, exactly as the contract asks: the app parses nothing out of it,
    // but a person reads it as the machine's receipt for the directory.
    await say(branch ? `${dir} on ${branch}` : dir);
    return;
  }

  if (prompt.startsWith("[ravix] Close this track") && dir) {
    const removed = removeTree(disk, dir);
    // A track on a bare machine is a plain directory rather than a worktree,
    // and the prompt asks for `rm -rf` accordingly. Echoing `git worktree
    // remove` at it would put a command in the transcript that was never sent.
    const worktree = prompt.includes("git worktree remove");
    emit({ kind: "output", stream: "acp", data: tool("t1", worktree ? `git worktree remove ${dir}` : `rm -rf ${dir}`) });
    await pause(300);
    emit({ kind: "output", stream: "acp", data: toolDone("t1", "") });
    disk.worktrees.delete(dir);
    await say(
      worktree
        ? `Removed ${dir} (${removed} files) and pruned the worktree record. The branch is untouched.`
        : `Removed ${dir} (${removed} files).`,
    );
    return;
  }

  if (prompt.startsWith("[ravix] Report what is on this machine")) {
    const worktrees = [...disk.worktrees].map(([path, w]) => ({ path, branch: w.branch, dirty: false }));
    const repos = [...new Set([...disk.worktrees.values()].map((w) => w.repoPath).filter((p): p is string => !!p))];
    emit({ kind: "output", stream: "acp", data: tool("t1", `ls -1 ${WORKSPACE_ROOT} && git worktree list`) });
    await pause(300);
    emit({ kind: "output", stream: "acp", data: toolDone("t1", worktrees.map((w) => `${w.path}  ${w.branch ?? "(detached)"}`).join("\n")) });
    disk.files.set(RECEIPT_PATH, JSON.stringify({ surveyed_at: now(), repos, worktrees }, null, 2));
    await say(worktrees.map((w) => `${w.path} ${w.branch ?? "(no branch)"}`).join("\n") || "No worktrees on this machine.");
    return;
  }

  // An ordinary turn from a person. It runs a command and answers from inside
  // the track's own directory, because saying so is the one thing the system
  // prompt spends its whole length on and a fake that wandered elsewhere would
  // be modelling the failure rather than the behaviour.
  const slug = parseChannel(conv.channel_id)?.trackSlug;
  const home = slug && disk.worktrees.has(`${WORK_ROOT}/${slug}`) ? `${WORK_ROOT}/${slug}` : [...disk.worktrees.keys()].find((d) => hasFilesUnder(disk, d)) ?? WORK_ROOT;
  updateMockPreview(home);
  // A checklist, as ACP reports one: the whole list every time, never a diff.
  emit({ kind: "output", stream: "acp", data: plan([["Look for open TODOs", "in_progress"], ["Say what is worth fixing", "pending"]]) });
  emit({ kind: "output", stream: "acp", data: thought("Start with whatever the code already admits is unfinished.") });
  emit({ kind: "output", stream: "acp", data: tool("x1", `rg -n "TODO|FIXME"`, home) });
  await pause(400);
  emit({ kind: "output", stream: "acp", data: toolDone("x1", "src/lib/window.ts:1:// TODO: rounding here is wrong across a DST boundary") });
  emit({ kind: "output", stream: "acp", data: thought("One hit. Read it before judging it.") });
  emit({ kind: "output", stream: "acp", data: tool("x2", "sed -n 1,20p src/lib/window.ts", home) });
  await pause(300);
  emit({ kind: "output", stream: "acp", data: toolDone("x2", "// TODO: rounding here is wrong across a DST boundary\nexport const dayOf = (ms: number) => Math.floor(ms / 86400000);") });
  emit({ kind: "output", stream: "acp", data: plan([["Look for open TODOs", "completed"], ["Say what is worth fixing", "in_progress"]]) });
  await say(
    `(mock) I am in ${home} and I read: ${prompt.trim().split("\n")[0]?.slice(0, 120)}\n\n` +
      "There is one TODO worth doing here — `dayOf` in `src/lib/window.ts` divides by 86400, which is an hour short twice a year. Say the word and I will fix it on this track's branch.",
  );
}

function hasFilesUnder(disk: Disk, dir: string): boolean {
  for (const path of disk.files.keys()) if (path.startsWith(`${dir}/`)) return true;
  return false;
}

const cancelledTurn = Symbol("cancelled turn");
const capacityKey = (conv: Conv) => `${conv.sandbox_id}:${conv.runtime}`;

function releaseTurn(conv: Conv): void {
  const key = capacityKey(conv);
  const holders = state.busy.get(key);
  holders?.delete(conv.id);
  if (holders?.size === 0) state.busy.delete(key);
}

function endTurn(conv: Conv, status: string): void {
  conv.turn_generation++;
  conv.status = status;
  releaseTurn(conv);
  for (const turn of state.turns.get(conv.id) ?? []) {
    if (turn.status === "running") turn.status = "interrupted";
  }
}

function deleteBox(box: Box): void {
  for (const conv of state.conversations) {
    if (conv.sandbox_id === box.id) endTurn(conv, "terminated");
  }
  box.status = "terminated";
  box.files.clear();
  box.worktrees.clear();
}

/** No provider queue: reserve capacity before scheduling any async work. */
function invalidateInference(set: { id: string; revision: number }): void {
  set.revision++;
  for (const conv of state.conversations) {
    if (conv.inference_credential_id === set.id) endTurn(conv, "terminated");
  }
}

function accept(conv: Conv, prompt: string, clientRequestId: string | null = null, images: PromptImage[] = [], attaching = false): { error: string } | null {
  const source = state.credentialSets.find(s => s.id === conv.inference_credential_id);
  if (source && source.revision !== conv.inference_revision) return { error: "inference_source_changed" };
  if (source) {
    const connected = conv.runtime === "codex" ? source.providers.includes("openai_api_key") || state.chatgptGrants.some(g => g.id === source.chatgpt_grant_id && g.status === "active") :
      source.providers.some(p => ["anthropic_api_key", "claude_code_oauth_token"].includes(p));
    if (!connected) return { error: "inference_credential_unusable" };
  }
  if (conv.status === "terminated") return { error: "conversation_terminated" };
  if (!state.boxes.has(conv.sandbox_id!)) return { error: "sandbox_not_found" };
  const key = capacityKey(conv);
  const holders = state.busy.get(key) ?? new Set<string>();
  if (holders.has(conv.id)) return { error: "conversation_busy" };
  const limit = Math.max(1, Number(process.env.MOCK_RUNTIME_CAPACITY || 1));
  if (holders.size >= limit) return { error: "sandbox_at_capacity" };
  holders.add(conv.id);
  state.busy.set(key, holders);
  conv.status = attaching ? "idle" : "running";
  void runTurn(conv, prompt, clientRequestId, images, attaching).catch((error) => {
    if (error === cancelledTurn) return;
    if (conv.status !== "terminated") endTurn(conv, "failed");
    console.error("mock: turn failed");
  });
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

/** Provider lifecycle control for deterministic mock contract tests. */
export function setSandboxStatus(id: string, status: "suspended" | "ready"): void {
  const box = state.boxes.get(id);
  if (!box) throw new Error("No such mock sandbox");
  box.status = status;
}

export async function fountain(req: Request, url: URL): Promise<Response | null> {
  const p = url.pathname;
  const method = req.method;
  // The bearer token is read and ignored on purpose: ravix holds exactly
  // one Fountain key for everybody, and rejecting a wrong one here would only
  // ever catch a typo in the dev command line.
  const body = method === "POST" || method === "PUT" || method === "PATCH" ? ((await req.json().catch(() => ({}))) as Record<string, unknown>) : {};

  if (p === "/api/auth/me") {
    return json({ data: { id: "u-mock", email: "ravix@example.com", chatgpt_subscriptions_enabled: true } });
  }

  if (p === "/api/catalog") {
    return json({
      data: {
        runtimes: ["claude", "codex"],
        models: {
          claude: ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"],
          codex: ["openai/gpt-6-astra", "openai/gpt-5.5"],
        },
        package_managers: ["apt", "npm"],
        mcp_servers: [],
      },
    });
  }

  // ── who pays for the model ───────────────────────────────────────────

  const SETS = "/api/account/inference-credential-sets";
  if (p === SETS) {
    // Default first, then by name, which is the order Ravix relies on to see
    // whether the account has a default at all.
    const listed = [...state.credentialSets].sort(
      (a, b) => Number(b.is_default) - Number(a.is_default) || a.name.localeCompare(b.name),
    );
    if (method === "GET") return json({ data: listed });
    if (method === "POST") {
      const name = String(body.name ?? "").trim();
      if (!name) return json({ error: "validation_failed", errors: { name: ["can't be blank"] } }, 422);
      if (state.credentialSets.some((set) => set.name === name)) {
        return json(
          { error: "validation_failed", errors: { name: ["already names a credential set on this account"] } },
          422,
        );
      }
      // The first set an account makes is its default. That is Fountain's
      // rule and the reason Ravix makes an empty one of its own first.
      const set = {
        id: `set${state.credentialSets.length + 1}-${Math.random().toString(36).slice(2, 8)}`,
        name,
        is_default: state.credentialSets.length === 0,
        revision: 0,
        providers: [] as string[],
        chatgpt_grant_id: null,
      };
      state.credentialSets.push(set);
      return json({ data: set }, 201);
    }
  }
  const setOne = new RegExp(`^${SETS}/([^/]+)$`).exec(p);
  if (setOne && method === "PATCH") {
    const set = state.credentialSets.find((s) => s.id === setOne[1]);
    if (!set) return json({ error: "not_found" }, 404);
    // Naming a subscription is the switch that makes Codex run on it, and
    // `null` turns it off. Fountain refuses a subscription the account does
    // not hold, and one that is disconnected.
    if ("chatgpt_grant_id" in body) {
      const wanted = body.chatgpt_grant_id;
      if (wanted !== null) {
        const grant = state.chatgptGrants.find((g) => g.id === wanted);
        if (!grant || grant.status !== "active") {
          return json({ error: "validation_failed", errors: { chatgpt_grant_id: ["is not a usable subscription"] } }, 422);
        }
      }
      set.chatgpt_grant_id = typeof wanted === "string" ? wanted : null;
      invalidateInference(set);
    }
    const grant = state.chatgptGrants.find((g) => g.id === set.chatgpt_grant_id);
    return json({ data: { ...set, chatgpt_grant: grant ? { id: grant.id, name: grant.name, status: grant.status } : null } });
  }

  // ── ChatGPT subscriptions ────────────────────────────────────────────

  const CHATGPT = "/api/account/chatgpt-subscriptions";
  // The ChatGPT account a sign-in under `name` is signing in as: this
  // person's own, unless a test has pinned every sign-in to one account.
  const chatgptAccount = (name: string) =>
    state.chatgptIdentity ?? `${name.replace(/[^a-zA-Z0-9]+/g, "-")}@chatgpt.example`;
  const attemptView = (a: (typeof state.chatgptAttempts)[number]) => ({
    id: a.id,
    kind: a.kind,
    name: a.name,
    grant_id: a.grant_id,
    state: a.state,
    user_code: a.state === "pending" ? "MOCK-CODE" : null,
    verification_url: a.state === "pending" ? "https://auth.openai.com/codex/device" : null,
    poll_interval: 1,
    auth_unreachable: false,
    expires_at: a.expires_at,
    result_grant_id: a.result_grant_id,
    // Fountain writes a failure as {reason, grant_id, grant}: the conflicting
    // grant's id and its name, and both null when it is not this account's.
    failure: a.failure,
  });
  if (p === CHATGPT && method === "GET") {
    return json({ data: state.chatgptGrants, count: state.chatgptGrants.length, limit: 5, linking_enabled: true });
  }
  if (p === `${CHATGPT}/attempts` && method === "GET") {
    return json({ data: state.chatgptAttempts.filter((a) => a.state === "pending").map(attemptView) });
  }
  if (p === `${CHATGPT}/attempts` && method === "POST") {
    const name = typeof body.name === "string" ? body.name.trim() : null;
    const grantId = typeof body.grant_id === "string" ? body.grant_id : null;
    if ((name && grantId) || (!name && !grantId)) {
      return json({ error: "validation_failed", errors: { name: ["give a name for a new subscription, or a grant_id to reconnect one"] } }, 422);
    }
    if (grantId && !state.chatgptGrants.some((g) => g.id === grantId)) return json({ error: "not_found" }, 404);
    if (name && state.chatgptGrants.some((g) => g.name === name)) {
      return json({ error: "validation_failed", errors: { name: ["already names a subscription"] } }, 422);
    }
    const open = state.chatgptAttempts.filter((a) => a.state === "pending");
    const same = open.find((a) => (name ? a.name === name : a.grant_id === grantId));
    if (same) return json({ error: "chatgpt_link_attempt_pending", attempt_id: same.id }, 409);
    if (open.length >= 3) return json({ error: "chatgpt_link_attempts_exceeded" }, 409);
    if (name && state.chatgptGrants.length >= 5) {
      return json({ error: "chatgpt_grant_limit_reached", count: state.chatgptGrants.length, limit: 5 }, 409);
    }
    const attempt = {
      id: `att${state.chatgptAttempts.length + 1}-${Math.random().toString(36).slice(2, 8)}`,
      kind: grantId ? ("reconnect" as const) : ("link" as const),
      name,
      grant_id: grantId,
      state: "pending",
      polls: 0,
      result_grant_id: null,
      failure: null,
      expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
    };
    state.chatgptAttempts.push(attempt);
    return json({ data: attemptView(attempt) }, 201);
  }
  const attemptOne = new RegExp(`^${CHATGPT}/attempts/([^/]+)$`).exec(p);
  if (attemptOne) {
    const attempt = state.chatgptAttempts.find((a) => a.id === attemptOne[1]);
    if (!attempt) return json({ error: "not_found" }, 404);
    if (method === "DELETE") {
      if (attempt.state !== "pending" && attempt.state !== "cancelled") {
        return json({ error: "chatgpt_link_attempt_not_pending", state: attempt.state }, 409);
      }
      attempt.state = "cancelled";
      return json({ data: attemptView(attempt) });
    }
    if (method === "GET") {
      if (attempt.state === "pending" && ++attempt.polls >= 3) {
        if (attempt.name?.includes("refused")) {
          attempt.state = "failed";
          attempt.failure = { reason: "invalid_sign_in" };
        } else if (attempt.grant_id) {
          const grant = state.chatgptGrants.find((g) => g.id === attempt.grant_id)!;
          grant.status = "active";
          attempt.state = "completed";
          attempt.result_grant_id = grant.id;
        } else {
          // Fountain refuses a second link of the same ChatGPT *account*, so
          // that is what is looked for --- not a second link of any kind. Each
          // sign-in is its own account unless a test pinned them together.
          const email = chatgptAccount(attempt.name!);
          const held = state.chatgptGrants.find((g) => g.account_email === email);
          if (held) {
            attempt.state = "failed";
            attempt.failure = { reason: "account_already_linked", grant_id: held.id, grant: held.name };
          } else {
            const grant = {
              id: `grant${state.chatgptGrants.length + 1}-${Math.random().toString(36).slice(2, 8)}`,
              name: attempt.name!,
              status: "active",
              plan_type: "plus",
              account_email: email,
            };
            state.chatgptGrants.push(grant);
            attempt.state = "completed";
            attempt.result_grant_id = grant.id;
          }
        }
      }
      return json({ data: attemptView(attempt) });
    }
  }
  const grantDisconnect = new RegExp(`^${CHATGPT}/([^/]+)/disconnect$`).exec(p);
  if (grantDisconnect && method === "POST") {
    const grant = state.chatgptGrants.find((g) => g.id === grantDisconnect[1]);
    if (!grant) return json({ error: "not_found" }, 404);
    grant.status = "disconnected";
    for (const set of state.credentialSets) if (set.chatgpt_grant_id === grant.id) invalidateInference(set);
    return json({ data: grant });
  }
  const grantOne = new RegExp(`^${CHATGPT}/([^/]+)$`).exec(p);
  if (grantOne && grantOne[1] !== "attempts" && (method === "DELETE" || method === "PATCH")) {
    const grant = state.chatgptGrants.find((g) => g.id === grantOne[1]);
    if (!grant) return json({ error: "not_found" }, 404);
    if (method === "DELETE") {
      // Gone entirely, which is what frees the ChatGPT account to be linked
      // again. A set left naming it stops being able to run Codex.
      state.chatgptGrants = state.chatgptGrants.filter((g) => g.id !== grant.id);
      for (const set of state.credentialSets) {
        if (set.chatgpt_grant_id === grant.id) {
          set.chatgpt_grant_id = null;
          invalidateInference(set);
        }
      }
      return new Response(null, { status: 204 });
    }
    const name = typeof body.name === "string" ? body.name.trim() : null;
    if (!name) return json({ error: "validation_failed", errors: { name: ["is required"] } }, 422);
    if (state.chatgptGrants.some((g) => g.id !== grant.id && g.name === name)) {
      return json({ error: "validation_failed", errors: { name: ["already names a subscription"] } }, 422);
    }
    grant.name = name;
    return json({ data: grant });
  }
  const credential = new RegExp(`^${SETS}/([^/]+)/credentials/([a-z_]+)$`).exec(p);
  if (credential) {
    const set = state.credentialSets.find((s) => s.id === credential[1]);
    const provider = credential[2]!;
    if (!set) return json({ error: "not_found" }, 404);
    if (!["anthropic_api_key", "claude_code_oauth_token", "openai_api_key", "gemini_api_key"].includes(provider)) {
      return json({ error: "validation_failed" }, 422);
    }
    if (method === "DELETE") {
      set.providers = set.providers.filter((held) => held !== provider);
      invalidateInference(set);
      return new Response(null, { status: 204 });
    }
    if (method === "PUT") {
      const value = String(body.value ?? "").trim();
      if (!value) return json({ error: "value is required", reason: "empty_value" }, 422);
      // Fountain asks the provider whether the value works. Here, anything
      // containing "invalid" does not, so the refusal can be seen in
      // development without a real key to revoke.
      if (value.includes("invalid")) {
        return json(
          { error: "the provider rejected this credential (HTTP 401)", reason: "invalid", provider_status: 401 },
          422,
        );
      }
      if (!set.providers.includes(provider)) set.providers = [...set.providers, provider].sort();
      invalidateInference(set);
      return json({ data: { provider, set: true } });
    }
  }

  // Copy atomically, without exposing values. The fixture account is mock-user.
  const vaultCopy = /^\/api\/vaults\/([^/]+)\/copy$/.exec(p);
  if (vaultCopy && method === "POST") {
    const source = state.vaults.find((v) => v.id === vaultCopy[1] &&
      (v.user_id ?? "mock-user") === "mock-user");
    if (!source) return json({ error: "not_found" }, 404);
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (!name || state.vaults.some((v) => v.name === name &&
      (v.user_id ?? "mock-user") === "mock-user")) {
      return json({ error: "invalid_name" }, 422);
    }
    const secrets = secretsFor("vaults", String(source.id));
    for (const [key, value] of secrets) {
      if (value === "mock:cannot-decrypt") {
        return json({ error: "secret_not_copyable", key }, 422);
      }
    }
    const copy = { id: crypto.randomUUID(), user_id: "mock-user", name,
      description: body.description ?? source.description ?? null,
      metadata: body.metadata ?? source.metadata ?? {}, secret_count: secrets.size };
    state.secrets.set(`vaults:${copy.id}`, new Map(secrets));
    state.vaults.push(copy);
    return json({ data: copy }, 201);
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
        const record = { ...(collection === "environments" ? { env_vars: {} } : {}), id: `${collection[0]}${list.length + 1}-${Math.random().toString(36).slice(2, 8)}`, ...body };
        list.push(record);
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
        if (collection === "agents") {
          for (const box of state.boxes.values()) {
            if (box.agent_id === id) deleteBox(box);
            else if (box.guest_agent_id === id) {
              for (const conv of state.conversations) {
                if (conv.agent_id === id && conv.sandbox_id === box.id) endTurn(conv, "terminated");
              }
              box.guest_agent_id = null;
            }
          }
        }
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

    const agent = state.agents.find((a) => a.id === agentId);
    if (!agent) return json({ error: "agent_not_found" }, 404);
    const runtime = String(agent.runtime ?? "claude");
    const sourceId = b.inference_credential_id ?? agent.inference_credential_id ?? null;
    if (b.inference_credential_id && b.inference_credential_id !== agent.inference_credential_id &&
        !(agent.allowed_inference_credential_ids as string[] | undefined)?.includes(b.inference_credential_id)) {
      return json({ error: "inference_credential_not_allowed" }, 422);
    }
    const source = state.credentialSets.find(s => s.id === sourceId);
    const userId = String(agent.user_id ?? "mock-user");
    const environmentId = b.environment_id ?? null;
    const vaultId = b.vault_id ?? null;
    let box: Box | undefined;
    if (b.sandbox_id) {
      box = state.boxes.get(b.sandbox_id);
      if (!box) return json({ error: "sandbox_not_found" }, 404);
      if (box.user_id !== userId || box.environment_id !== environmentId || box.vault_id !== vaultId) {
        return json({ error: "sandbox_identity_mismatch" }, 422);
      }
      if (box.agent_id === agentId) {
        if (box.runtime !== runtime) return json({ error: "sandbox_runtime_mismatch" }, 422);
      } else {
        if (box.runtime === runtime || (box.guest_agent_id && box.guest_agent_id !== agentId)) {
          return json({ error: "sandbox_runtime_mismatch" }, 422);
        }
      }
    } else {
      box = [...state.boxes.values()].find((box) => box.agent_id === agentId &&
        box.user_id === userId && box.environment_id === environmentId && box.vault_id === vaultId &&
        !["terminated", "failed"].includes(box.status));
      if (box && box.runtime !== runtime) return json({ error: "sandbox_runtime_mismatch" }, 422);
      if (!box) {
        if (!b.prompt?.trim()) return json({ error: "initial_prompt_required" }, 422);
        box = {
          runtime, user_id: userId, guest_agent_id: null,
          id: `sb-${crypto.randomUUID()}`,
          sprite_name: `ravix-${Math.random().toString(36).slice(2, 8)}`,
          status: "ready", provider: "mock", mode: "persistent",
          agent_id: agentId, environment_id: environmentId, vault_id: vaultId, url: null,
          files: new Map(), worktrees: new Map(),
        };
        const environment = state.environments.find((env) => env.id === environmentId);
        for (const repo of (environment?.repositories as {mount_path?: string}[] | undefined) ?? []) {
          if (repo.mount_path) seedClone(box, repo.mount_path);
        }
        state.boxes.set(box.id, box);
      }
    }

    const conv: Conv = {
      id: `c${state.conversations.length + 1}-${Math.random().toString(36).slice(2, 8)}`,
      title: b.title ?? null,
      sandbox_id: box!.id,
      agent_id: agentId,
      vault_id: b.vault_id ?? null,
      environment_id: b.environment_id ?? null,
      runtime,
      turn_generation: 0,
      inference_credential_id: typeof sourceId === "string" ? sourceId : null,
      inference_revision: source?.revision ?? 0,
      status: "idle",
      channel_id: b.channel_id ?? null,
      turn_count: 0,
      last_active_at: null,
      inserted_at: now(),
      model: typeof b.model === "string" ? b.model : null,
    };
    // A prompt sent with the launch is the first turn. Ravix sends the
    // opening turn this way on the launch that *provisions* the box and
    // separately on an attach, so a mock that ignored it would leave every
    // brand-new project's first track sitting in `opening` forever.
    const first = typeof b.prompt === "string" ? b.prompt : "";
    if (first.trim()) {
      const refusal = accept(conv, first, null, [], Boolean(b.sandbox_id && box.agent_id !== agentId));
      if (refusal) return json(refusal, 409);
    }
    if (box.agent_id !== agentId) box.guest_agent_id = agentId;
    state.conversations.push(conv);
    return json({ data: withBox(conv) });
  }

  const convPrompt = /^\/api\/conversations\/([^/]+)\/prompts$/.exec(p);
  if (convPrompt) {
    const conv = state.conversations.find((c) => c.id === convPrompt[1]);
    if (!conv) return json({ error: "not_found" }, 404);
    const { prompt, client_request_id, images } = body as { prompt?: unknown; client_request_id?: unknown; images?: PromptImage[] };
    const refused = accept(conv, String(prompt ?? ""), typeof client_request_id === "string" ? client_request_id : null, images ?? []);
    if (refused) return json(refused, 409);
    return json({ status: "accepted" });
  }

  const convStream = /^\/api\/conversations\/([^/]+)\/stream$/.exec(p);
  if (convStream) return sse(convStream[1]!);

  const convEvents = /^\/api\/conversations\/([^/]+)\/events$/.exec(p);
  if (convEvents) {
    const conversationId = convEvents[1]!;
    // Oldest first after the cursor, a page at a time, the way Fountain pages
    // it: `next_cursor` is the last id served, and a reader follows it until
    // `has_more` is false. That is how the follower reads back the one event
    // it needs. `order=desc` is managoat/fountain#2531: the newest events
    // first, below `before`, and with `whole_turns=true` never ending a page
    // inside a turn (up to 5,000 events, then `page.turn_split`).
    const after = Number(url.searchParams.get("after") ?? 0) || 0;
    const beforeParam = url.searchParams.get("before");
    const before = beforeParam ? Number(beforeParam) : Infinity;
    const limit = Math.min(Number(url.searchParams.get("limit") ?? 100) || 100, 1000);
    const order = url.searchParams.get("order") === "desc" ? "desc" : "asc";
    const wholeTurns = url.searchParams.get("whole_turns") === "true";
    if (wholeTurns && order !== "desc") return json({ error: "invalid_parameters", message: "whole_turns requires order=desc." }, 422);
    const all = (state.events.get(conversationId) ?? []).filter((ev) => (ev.id as number) > after && (ev.id as number) < before);
    const { page, hasMore, turnSplit } = order === "desc"
      ? backwardPage(all, limit, wholeTurns)
      : { page: all.slice(0, limit), hasMore: all.length > limit, turnSplit: false };
    const ids = page.map((ev) => ev.id as number);
    const blocks = url.searchParams.get("blocks") === "true";
    const prompts = blocks && url.searchParams.get("prompts") === "true";
    const turns = state.turns.get(conversationId) ?? [];
    // Only what the transcript reads off `blocks`: the prompt on a turn's
    // opening event. Fountain's own parse of every output event is not
    // modelled, because nothing here reads it.
    const data = blocks
      ? page.map((ev) => {
          const opens = ev.kind === "stage" && ev.stage === "turn" && ev.state === "started";
          const turn = opens && prompts ? turns.find((t) => t.id === ev.turn_id) : undefined;
          const prompt = typeof turn?.prompt === "string" && turn.prompt !== "" ? turn.prompt : null;
          return { ...ev, blocks: prompt ? [{ kind: "prompt", body: prompt }] : [] };
        })
      : page;
    return json({
      data,
      meta: { limit, has_more: hasMore, next_cursor: page.length ? page[page.length - 1]!.id : null },
      page: {
        order,
        oldest_cursor: ids.length ? Math.min(...ids) : null,
        newest_cursor: ids.length ? Math.max(...ids) : null,
        turn_split: turnSplit,
      },
    });
  }

  const turnImage = /^\/api\/conversations\/([^/]+)\/turns\/([^/]+)\/images\/(\d+)$/.exec(p);
  if (turnImage) {
    const turn = state.turns.get(turnImage[1]!)?.find(t => t.id === turnImage[2]);
    const image = (turn?.images as PromptImage[] | undefined)?.[Number(turnImage[3])];
    return image
      ? new Response(Buffer.from(image.data, "base64"), { headers: { "content-type": image.media_type } })
      : new Response("Not Found", { status: 404 });
  }

  const convTurns = /^\/api\/conversations\/([^/]+)\/turns$/.exec(p);
  if (convTurns) return json({ data: (state.turns.get(convTurns[1]!) ?? []).map(({ images, ...turn }) => turn) });

  // Only the `model` half of reapply (ADR 0061): omitted keeps it, null
  // follows the agent again, and a turn in flight is refused as Fountain does.
  const convReapply = /^\/api\/conversations\/([^/]+)\/reapply$/.exec(p);
  if (convReapply && req.method === "POST") {
    const conv = state.conversations.find((c) => c.id === convReapply[1]);
    if (!conv) return json({ error: "not_found", message: "Conversation not found" }, 404);
    if (conv.status === "running" || conv.status === "pending")
      return json({ error: "conversation_busy", message: "A turn is running" }, 409);
    const b = body as { model?: unknown };
    if ("model" in b) conv.model = typeof b.model === "string" ? b.model : null;
    return json({ data: withBox(conv) });
  }

  const convAction = /^\/api\/conversations\/([^/]+)\/(interrupt|terminate)$/.exec(p);
  if (convAction && method === "POST") {
    const conv = state.conversations.find((c) => c.id === convAction[1]);
    if (conv) {
      endTurn(conv, convAction[2] === "terminate" ? "terminated" : "idle");
    }
    return json({ status: "ok" });
  }

  const convOne = /^\/api\/conversations\/([^/]+)$/.exec(p);
  if (convOne) {
    const conv = state.conversations.find((c) => c.id === convOne[1]);
    return conv ? json({ data: withBox(conv) }) : json({ error: "not_found" }, 404);
  }

  if (p === "/api/sandboxes") {
    if (method !== "GET") return json({ error: "method_not_allowed" }, 405);
    const statuses = url.searchParams.get("status")?.split(",");
    return json({ data: [...state.boxes.values()].filter(box => !statuses || statuses.includes(box.status)).map(publicBox) });
  }

  const boxPath = /^\/api\/sandboxes\/([^/]+)(?:\/.*)?$/.exec(p);
  const disk = boxPath ? state.boxes.get(decodeURIComponent(boxPath[1]!)) : undefined;
  if (boxPath && !disk) return json({ error: "sandbox_not_found" }, 404);
  if (boxPath && p !== `/api/sandboxes/${boxPath[1]}` && method !== "GET") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // ── the box, read-only ───────────────────────────────────────────────

  // Fountain's passive disk reads never wake a parked sandbox.
  if (disk && /\/api\/sandboxes\/[^/]+\/(files|file|diff)$/.test(p) && disk.status !== "ready") {
    return json({
      error: "sandbox_not_ready",
      message: `the sandbox is ${disk.status}; files are read from a ready one only`,
      status: disk.status,
    }, 409);
  }

  const sbFiles = /^\/api\/sandboxes\/([^/]+)\/files$/.exec(p);
  if (sbFiles && disk) {
    const dir = (url.searchParams.get("path") ?? "/").replace(/\/+$/, "");
    const seen = new Map<string, { name: string; type: string; size: number | null }>();
    for (const [path, content] of disk.files) {
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
  if (sbFile && disk) {
    const path = url.searchParams.get("path") ?? "";
    const content = disk.files.get(path);
    if (content === undefined) return json({ error: "not_found" }, 404);
    return json({ data: { path, size: content.length, truncated: false, encoding: "utf8", content } });
  }

  const sbDiff = /^\/api\/sandboxes\/([^/]+)\/diff$/.exec(p);
  if (sbDiff && disk) {
    const path = url.searchParams.get("path") ?? "";
    const worktree = disk.worktrees.get(path);
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
  if (sbOne && disk) {
    if (method === "DELETE") {
      if (["terminated", "failed"].includes(disk.status)) {
        return json({ error: "sandbox_not_resettable" }, 422);
      }
      deleteBox(disk);
      return new Response(null, { status: 204 });
    }
    if (method === "GET") return json({ data: publicBox(disk) });
    return json({ error: "method_not_allowed" }, 405);
  }

  return null;
}

function publicBox(box: Box) {
  const { files: _files, worktrees: _worktrees, ...record } = box;
  return record;
}
const withBox = (c: Conv) => {
  const box = c.sandbox_id ? state.boxes.get(c.sandbox_id) : null;
  return { ...c, sandbox: box ? publicBox(box) : null };
};

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
  ...(process.env.RAVIX_BROWSER_TEST === "1" ? [
    { id: 9003, login: "threadruntime", name: "Thread Runtime", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9004, login: "privacycreator", name: "Privacy Creator", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9005, login: "privacyguest", name: "Privacy Guest", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9006, login: "filterowner", name: "Filter Owner", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9007, login: "filtermember", name: "Filter Member", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9008, login: "commenter", name: "Comment Author", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9009, login: "workspacecreator", name: "Workspace Creator", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9010, login: "workspacecolleague", name: "Workspace Colleague", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9011, login: "teamowner", name: "Team Owner", avatar_url: `${BASE}/ghweb/avatar.svg` },
    { id: 9012, login: "teammate", name: "Team Mate", avatar_url: `${BASE}/ghweb/avatar.svg` },
  ] : []),
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
  { name: "ravix-notes", private: false, language: null, description: "Design notes, mostly markdown.", pushed_at: "2026-08-28T14:51:02Z" },
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
   * The App's own view of one installation (ADR 0009 phase 4b): a workspace
   * connecting GitHub checks the installation exists, and a catalog refresh
   * reads whether it is suspended. Only the one installation this mock has.
   */
  const appInstallation = /^\/app\/installations\/(\d+)$/.exec(p);
  if (appInstallation) {
    if (Number(appInstallation[1]) !== INSTALLATION_ID) return json({ message: "Not Found" }, 404);
    return json({
      id: INSTALLATION_ID,
      account: { login: VIEWER.login, avatar_url: VIEWER.avatar_url },
      suspended_at: null,
    });
  }

  /** Every repository the installation grants, read with its own token. */
  if (p === "/installation/repositories") {
    const page = Number(url.searchParams.get("page") ?? "1");
    const repositories = page > 1 ? [] : REPOS.map((r) => repoBody(r.name));
    return json({ total_count: REPOS.length, repositories });
  }

  /**
   * One account by login, which is how somebody with no ravix account
   * gets invited. A short allowlist rather than "anything is a person":
   * inviting a name that does not exist has to stay reachable offline, because
   * the honest 404 is the more interesting of the two answers.
   */
  const byLogin = /^\/users\/([^/]+)$/.exec(p);
  if (byLogin) {
    const login = decodeURIComponent(byLogin[1]!).toLowerCase();
    const known: Record<string, number> = { octocat: 583231, hubot: 5153, dana: 9001, eli: 9002 };
    if (login === VIEWER.login.toLowerCase()) return json(VIEWER);
    const id = known[login] ?? PEOPLE.find(person => person.login.toLowerCase() === login)?.id;
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
      "Authorize Ravix",
      `<h1>Authorize Ravix</h1>
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
   * and `RAVIX_URL` is that. It lands with `installation_id` and no
   * `code`, which is the branch in `auth.callback` that means "already signed
   * in, just granted access".
   */
  const install = /^\/apps\/([^/]+)\/installations\/new$/.exec(p);
  if (install) {
    const state = url.searchParams.get("state");
    // A workspace's "Connect GitHub" (ADR 0009 phase 4b, a `ws.` state)
    // needs GitHub's user-to-server `code` too, as an App with "Request user
    // authorization (OAuth) during installation" sends it: Ravix reads the
    // returning person's own installations with it before binding one.
    const back = `${APP_URL}/api/auth/callback?${new URLSearchParams({
      installation_id: String(INSTALLATION_ID),
      setup_action: "install",
      ...(state ? { state } : {}),
      ...(state?.startsWith("ws.") ? { code: `install:${VIEWER.login}` } : {}),
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

if (import.meta.main) {
({ updateMockPreview } = await import("./previews"));
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

    if (p === "/__browser/long-transcript" && req.method === "POST" && process.env.RAVIX_BROWSER_TEST === "1") {
      const { id } = await req.json() as { id: string };
      const conv = state.conversations.find(c => c.id === id);
      if (!conv) return json({ error: "invalid_fixture" }, 400);
      const records = state.turns.get(id) ?? [];
      // 350 turns of 20 events: 7,000 in all, and a 200-event page is ten whole turns.
      for (let i = 1; i <= 350; i++) {
        const turn = `history-${id}-${i}`;
        records.push({ id: turn, prompt: `History prompt ${i}`, status: "completed", image_count: 0 });
        push(id, { kind: "stage", stage: "turn", state: "started", turn_id: turn });
        for (let j = 0; j < 18; j++) {
          push(id, { kind: "output", stream: "acp", turn_id: turn,
            data: text(`History answer ${i}: line ${j}.\n\n`) });
        }
        push(id, { kind: "stage", stage: "turn", state: "completed", turn_id: turn });
      }
      state.turns.set(id, records);
      conv.turn_count += 350;
      return json({ status: "ok" });
    }

    // Make two Ravix logins sign in as one ChatGPT account, which is the only
    // way `account_already_linked` happens. Off by default: every sign-in is
    // its own account, so ordinary specs that link several people never
    // collide. `{"identity": null}` puts that default back.
    if (p === "/__browser/chatgpt-account" && req.method === "POST" && process.env.RAVIX_BROWSER_TEST === "1") {
      const { identity } = await req.json() as { identity?: string | null };
      if (identity !== null && (typeof identity !== "string" || identity === "")) {
        return json({ error: "invalid_fixture" }, 400);
      }
      state.chatgptIdentity = identity;
      return json({ status: "ok" });
    }

    // Deterministic provider states for the real-browser composer matrix.
    if (p === "/__browser/conversation-state" && req.method === "POST" && process.env.RAVIX_BROWSER_TEST === "1") {
      const { id, status, emit = false } = await req.json() as { id: string; status: string; emit?: boolean };
      const conv = state.conversations.find(c => c.id === id);
      if (!conv || !["idle", "pending", "running", "failed"].includes(status)) return json({ error: "invalid_fixture" }, 400);
      conv.status = status;
      if (emit) push(id, { kind: "stage", stage: "turn", turn_id: "browser-activity",
        state: ({ idle: "completed", pending: "queued", running: "started", failed: "failed" } as Record<string, string>)[status] });
      return json({ status: "ok" });
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
const keyPath = process.env.MOCK_KEY_PATH || join(import.meta.dir, "dev-key.pem");
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
    "Run the server against it, from the repository root:",
    "",
    `  FOUNTAIN_URL=${BASE} FOUNTAIN_API_KEY=ftn_mock \\`,
    `  SPRITES_TOKEN=sprites_mock SPRITES_URL=http://localhost:${process.env.MOCK_SPRITES_PORT || 8794} PREVIEW_DOMAIN=preview.localhost \\`,
    `  GITHUB_API_URL=${BASE}/gh GITHUB_WEB_URL=${BASE}/ghweb \\`,
    "  GITHUB_APP_ID=1 GITHUB_APP_SLUG=ravix-mock \\",
    "  GITHUB_CLIENT_ID=Iv1.mock GITHUB_CLIENT_SECRET=mocksecret \\",
    '  GITHUB_PRIVATE_KEY="$(cat mock/dev-key.pem)" \\',
    `  PUBLIC_URL=${APP_URL} STATIC_DIR= DATA_DIR=./data \\`,
    "  bun --watch server/index.ts",
    "",
    `  bun run dev        # the SPA on ${APP_URL}, proxying /api to :8081`,
    "",
  ].join("\n"),
);

}
