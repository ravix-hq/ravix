/**
 * Running a command on the machine.
 *
 * Fountain deliberately has no exec: reads of a sandbox are free, and every
 * *write* to the box is a turn taken by the agent that lives on it. That is
 * the right boundary for Fountain and it is why paddock's terminal is a
 * Claude Code prompt rendered as scrollback rather than a shell.
 *
 * Switchyard goes one layer down. Fountain's sandboxes run on Sprites, and a
 * sandbox tells you the name of its sprite (`sandbox.sprite_name`), so a
 * server holding a Sprites token can talk to the same machine directly. That
 * buys the two panels an agent conversation genuinely cannot give you: a
 * terminal, and a run command whose output you watch.
 *
 * Three things about this are worth being clear-eyed about, and the UI says
 * all three rather than leaving them to be discovered:
 *
 *   1. **It is optional.** No `SPRITES_TOKEN`, no terminal — and switchyard
 *      still works completely, because everything else goes through Fountain.
 *      The panels render a designed empty state naming the missing variable.
 *   2. **It is not a PTY.** Sprites' exec is one HTTP request in, a
 *      multiplexed byte stream out, and then it is over. `ls`, `git status`
 *      and `npm test` are exactly right. `vim` and `top` are not, and the
 *      panel says so where somebody would type them.
 *   3. **It is out of band.** These commands do not go through Fountain, so
 *      they are not turns, they do not appear in the transcript, and they do
 *      not wait for the box's one-turn-at-a-time lock. That is the feature —
 *      you can look around while the agent is working — and also the risk,
 *      which is why exec is confined to a track's own worktree by `resolveCwd`
 *      below rather than by asking nicely.
 */

/** Sprites' exec frames its output: 1 = stdout, 2 = stderr, 3 = exit code. */
const FRAME_STDOUT = 1;
const FRAME_STDERR = 2;
const FRAME_EXIT = 3;

export interface SpriteService {
  name: string;
  state?: { status: string; restart_count?: number; exit_code?: number };
}

export interface SpritesConfig {
  token: string;
  baseUrl: string;
}

export interface RawExec {
  stdout: string;
  stderr: string;
  code: number;
}

export class SpritesError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

export class Sprites {
  constructor(private readonly cfg: SpritesConfig) {}

  async service(sprite: string, name: string): Promise<SpriteService | null> {
    const r = await this.serviceRequest(sprite, name, "GET", undefined, true);
    return r.status === 404 ? null : r.json();
  }

  async defineService(sprite: string, name: string, directory: string, command: string, port: number): Promise<string> {
    // No http_port: the machine-wide public route must never expose a preview.
    const r = await this.serviceRequest(sprite, `${name}?duration=1s`, "PUT", {
      cmd: "sh", args: ["-lc", command], dir: directory, env: { PORT: String(port), HOST: "127.0.0.1" }, needs: [],
    });
    return (await r.text()).slice(-32_000);
  }

  async serviceAction(sprite: string, name: string, action: "start" | "stop" | "delete"): Promise<string> {
    const path = action === "delete" ? name : `${name}/${action}?duration=1s`;
    const r = await this.serviceRequest(sprite, path, action === "delete" ? "DELETE" : "POST", undefined, action !== "start", action === "stop");
    return (await r.text()).slice(-32_000);
  }

  async serviceLogs(sprite: string, name: string): Promise<string> {
    const r = await this.exec(sprite, ["tail", "-c", "32000", `/.sprite/logs/services/${name}.log`], 15);
    return (r.stdout + r.stderr).slice(-32_000);
  }

  async activity(sprite: string, name: string, release = false): Promise<void> {
    const argv = ["curl", "--fail-with-body", "--silent", "--show-error", "--unix-socket", "/.sprite/api.sock",
      "-X", release ? "DELETE" : "PUT", `http://sprite/v1/tasks/${name}`];
    if (!release) argv.push("-H", "Content-Type: application/json", "-d", '{"expire":"2m"}');
    const result = await this.exec(sprite, argv, 15);
    if (result.code && !release) throw new SpritesError(501, "This Sprite does not support expiring preview activity tasks.");
  }

  private async serviceRequest(sprite: string, path: string, method: string, body?: unknown, missingOk = false, stoppedOk = false): Promise<Response> {
    const r = await fetch(`${this.cfg.baseUrl}/v1/sprites/${encodeURIComponent(sprite)}/services/${path}`, {
      method, headers: { authorization: `Bearer ${this.cfg.token}`, "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(25_000),
    });
    if (!r.ok && !(missingOk && r.status === 404)) {
      // A stopped process may be reported as failed (SIGTERM/exit 143).
      // Sprites answers a repeated stop with this specific conflict instead
      // of 2xx. Its desired outcome is already satisfied; other conflicts,
      // including start conflicts, must still be surfaced and retried.
      if (stoppedOk && r.status === 409 && (await r.text()).trim() === "service is not running") return new Response(null, { status: 204 });
      if (!r.bodyUsed) await r.body?.cancel();
      throw new SpritesError(r.status, `Sprites service operation failed (${r.status}). Check service support and the deployment token.`);
    }
    return r;
  }

  /**
   * One command, as an argv, on one sprite.
   *
   * The response body is a stream of frames rather than plain bytes, which is
   * how stdout and stderr stay separate and how the exit code arrives at all.
   * A frame is `<id byte><payload up to the next byte < 4>`; the exit frame is
   * two bytes. Reading it is twelve lines and the alternative — one merged
   * stream with the exit code printed at the end — loses the distinction the
   * terminal panel renders in a different colour.
   */
  async exec(spriteName: string, argv: string[], timeoutSec: number): Promise<RawExec> {
    const qs = new URLSearchParams();
    for (const a of argv) qs.append("cmd", a);
    const url = `${this.cfg.baseUrl}/v1/sprites/${encodeURIComponent(spriteName)}/exec?${qs}`;
    let res: Response;
    try {
      res = await fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${this.cfg.token}`, "content-type": "application/octet-stream" },
        signal: AbortSignal.timeout(timeoutSec * 1000 + 15_000),
      });
    } catch (err) {
      throw new SpritesError(502, err instanceof Error && err.name === "TimeoutError" ? "The machine did not answer in time." : "Could not reach the machine.");
    }
    if (!res.ok) {
      const detail = (await res.text().catch(() => "")).slice(0, 200);
      throw new SpritesError(
        res.status,
        res.status === 404
          ? "This machine is not reachable over Sprites — it may be asleep, or built somewhere this token cannot see."
          : `Sprites said ${res.status}. ${detail}`.trim(),
      );
    }
    return decodeFrames(new Uint8Array(await res.arrayBuffer()));
  }

  /**
   * A shell command, with its exit code and its final directory.
   *
   * The command runs under `sh -c` in `cwd`, and then the wrapper prints where
   * it ended up on its own line. That last part is what makes the terminal
   * feel like a terminal: `cd ..` has to be remembered by *something*, and
   * since each exec is a fresh process, the something is this line and the
   * cwd the client sends back with the next command.
   *
   * The marker is a random-looking sentinel rather than a newline convention
   * because a command's own output is arbitrary and will eventually contain
   * whatever separator you picked.
   */
  async shell(spriteName: string, command: string, cwd: string, timeoutSec: number): Promise<RawExec & { cwd: string }> {
    const marker = "__switchyard_cwd__";
    const script = `cd ${shq(cwd)} 2>/dev/null || cd /home/sprite; { ${command}\n }; __rc=$?; printf '\\n${marker}%s\\n' "$PWD"; exit $__rc`;
    const raw = await this.exec(spriteName, ["sh", "-lc", script], timeoutSec);
    const idx = raw.stdout.lastIndexOf(`\n${marker}`);
    if (idx === -1) return { ...raw, cwd };
    const after = raw.stdout.slice(idx + marker.length + 1);
    const nl = after.indexOf("\n");
    return {
      stdout: raw.stdout.slice(0, idx),
      stderr: raw.stderr,
      code: raw.code,
      cwd: (nl === -1 ? after : after.slice(0, nl)).trim() || cwd,
    };
  }

  /** Is this sprite reachable at all? Used to decide between two empty states. */
  async reachable(spriteName: string): Promise<boolean> {
    try {
      const r = await this.exec(spriteName, ["true"], 15);
      return r.code === 0;
    } catch {
      return false;
    }
  }
}

/**
 * Where a command is allowed to run.
 *
 * A track owns one directory and the terminal panel belongs to a track, so the
 * server pins `cwd` under that directory rather than trusting the client's.
 * The browser sends where it thinks it is; this decides. Without it the
 * terminal is a way to walk out of the worktree the whole app is built to keep
 * work inside of — the one rule the agent is told three times to follow would
 * be undone by a text box beneath it.
 *
 * Escaping upward is not an error the user needs a lecture about: it snaps
 * back to the root and the panel shows where it actually is.
 */
export function resolveCwd(root: string, requested: string | undefined): string {
  if (!requested) return root;
  const normalized = normalizePosix(requested.startsWith("/") ? requested : `${root}/${requested}`);
  const rootNorm = normalizePosix(root);
  return normalized === rootNorm || normalized.startsWith(`${rootNorm}/`) ? normalized : rootNorm;
}

function normalizePosix(p: string): string {
  const out: string[] = [];
  for (const part of p.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return `/${out.join("/")}`;
}

/** Single-quote for `sh`, the only quoting that is safe for arbitrary bytes. */
export function shq(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

/** The frame decoder, exported so `sprites.test.ts` can prove it against real bytes. */
export function decodeFrames(raw: Uint8Array): RawExec {
  const out: number[] = [];
  const err: number[] = [];
  let code = 0;
  let i = 0;
  while (i < raw.length) {
    const id = raw[i]!;
    if (id === FRAME_EXIT) {
      code = raw[i + 1] ?? 0;
      i += 2;
      continue;
    }
    i++;
    const start = i;
    while (i < raw.length && raw[i]! >= 4) i++;
    const payload = raw.subarray(start, i);
    if (id === FRAME_STDOUT) out.push(...payload);
    else if (id === FRAME_STDERR) err.push(...payload);
  }
  const dec = new TextDecoder();
  return { stdout: dec.decode(new Uint8Array(out)), stderr: dec.decode(new Uint8Array(err)), code };
}
