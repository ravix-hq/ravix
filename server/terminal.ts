/**
 * The terminal, and the run panel, which are the same thing twice.
 *
 * Both are `POST /api/tracks/:id/exec`. The difference is what the browser
 * sends: a line somebody typed, or the project's run command. Making them one
 * route rather than two is not tidiness — a run command is a shell command in
 * a directory, and giving it its own endpoint would give it its own idea of
 * where it runs, which is exactly the bug this app is built to prevent.
 *
 * Two constraints shape everything here.
 *
 * **Out of band.** These commands go to Sprites, not to Fountain. They are not
 * turns: they do not appear in the transcript, they do not queue behind the
 * agent's one-turn-at-a-time lock, and you can run `git status` while the
 * agent is mid-edit. That is the feature. It is also why `resolveCwd` pins
 * every command inside the track's own worktree — the terminal must not be the
 * hole in the one rule the agent is told three times to follow.
 *
 * **Not a PTY.** One request in, one response out. `ls`, `git log`, `npm test`
 * are exactly right. `vim`, `top` and anything that wants a tty are not, and
 * the panel says so above the prompt rather than letting somebody find out by
 * hanging for sixty seconds.
 */
import type { ExecResult } from "../shared/api";
import type { AppContext } from "./context";
import { authenticate, requireFountain, requireSprites, trackOf } from "./context";
import { resolveCwd, SpritesError } from "./sprites";
import { machineOf } from "./tracks";
import { HttpError, json, readJson, str } from "./http";

/** The ceiling on one command, in seconds. A build is fine; a server is not. */
const MAX_TIMEOUT_SEC = 120;
const DEFAULT_TIMEOUT_SEC = 60;

/** `POST /api/tracks/:id/exec` */
export async function exec(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  const sprites = requireSprites(ctx);
  const fountain = requireFountain(ctx);

  const body = await readJson(req);
  const command = str(body.command, 8000).trim();
  if (!command) throw new HttpError(422, "empty_command", "Type a command.");

  const machine = await machineOf(fountain, project);
  if (!machine) throw new HttpError(409, "no_machine", "This project has no machine yet. Open a track first.");
  if (!machine.spriteName) {
    // A real and reportable state rather than a 500: Fountain may be running
    // this sandbox on a provider that is not Sprites, in which case exec is
    // not "broken", it does not apply.
    throw new HttpError(501, "no_exec", "This machine does not expose a sprite, so switchyard cannot run commands on it directly.");
  }

  const cwd = resolveCwd(track.workdir, typeof body.cwd === "string" ? body.cwd : undefined);
  const timeoutSec = Math.min(MAX_TIMEOUT_SEC, Math.max(1, Number(body.timeoutSec) || DEFAULT_TIMEOUT_SEC));

  const startedAt = Date.now();
  try {
    const r = await sprites.shell(machine.spriteName, command, cwd, timeoutSec);
    const out: ExecResult = {
      stdout: r.stdout,
      stderr: r.stderr,
      code: r.code,
      // Where the shell actually ended up, so `cd` is remembered by the one
      // thing that can remember it: the next request.
      cwd: resolveCwd(track.workdir, r.cwd),
      timedOut: r.code === 124,
      durationMs: Date.now() - startedAt,
    };
    return json({ data: out });
  } catch (err) {
    if (err instanceof SpritesError) throw new HttpError(err.status >= 500 ? 502 : err.status, "exec_failed", err.message);
    throw new HttpError(502, "exec_failed", "The machine did not run that.");
  }
}

/**
 * `GET /api/tracks/:id/exec` — whether the terminal will work, before the
 * panel renders a prompt that cannot.
 *
 * Three distinct answers, and the panel renders a different empty state for
 * each: no token on this deployment, no machine yet, or a machine that is
 * asleep or unreachable. Collapsing them into one "unavailable" is how people
 * end up filing a bug about a feature that is off by configuration.
 */
export async function execStatus(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  if (!ctx.sprites) return json({ data: { available: false, why: "no_token", cwd: track.workdir } });

  const fountain = requireFountain(ctx);
  const machine = await machineOf(fountain, project).catch(() => null);
  if (!machine) return json({ data: { available: false, why: "no_machine", cwd: track.workdir } });
  if (!machine.spriteName) return json({ data: { available: false, why: "no_sprite", cwd: track.workdir } });

  const reachable = await ctx.sprites.reachable(machine.spriteName);
  return json({
    data: { available: reachable, why: reachable ? null : "unreachable", cwd: track.workdir },
  });
}
