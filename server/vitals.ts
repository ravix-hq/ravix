/**
 * How much of the machine is left.
 *
 * The rest of the app never asks this, and deliberately: a project is a
 * machine, the machine is Fountain's to size, and there is nothing in the UI
 * that would be improved by a gauge. But four tracks on one box share one CPU
 * allowance, one memory limit and one disk, and when the fourth `bun install`
 * of the afternoon starts swapping, the question "is it me or is it the box?"
 * has no other way to be answered from here. That is a power user's question,
 * so this is a power user's readout — one dim line, in the strip that already
 * belongs to the machine.
 *
 * It rides on the same route as the terminal, for the same reason: reads of a
 * Fountain sandbox cannot see `/proc`, so the only way to a load figure is
 * Sprites' exec, which means this panel has exactly the terminal's four
 * failure states and shares its answer for them.
 *
 * **Everything here is best-effort by design.** The numbers come from files
 * that a given kernel, runtime or image may not have: `cpu.max` and
 * `cpu.stat` are cgroup v2, `MemAvailable` arrived in Linux 3.14, and `df`
 * can be refused outright. So the probe reads whatever is there, reports
 * blanks for the rest, and this file's job is to turn that into a shape where
 * a number that could not be read is *absent* rather than zero. "0% CPU" and
 * "we could not tell" are different claims and only one of them is ever true.
 */
import type { MachineUnreachable, MachineVitals, VitalsReport } from "../shared/api";
import type { AppContext } from "./context";
import { authenticate, requireFountain, trackOf } from "./context";
import { shq } from "./sprites";
import { machineOf, spriteFor } from "./tracks";
import { json } from "./http";

/**
 * How long the two CPU samples are apart, as the shell will write it.
 *
 * Short enough that the whole request stays under half a second, long enough
 * that the delta is not dominated by the cost of reading it. The elapsed time
 * is measured rather than assumed — `sleep 0.3` is a GNU nicety that busybox
 * may round to a second — so this is only a target.
 */
const SAMPLE = "0.3";

/** The probe is three file reads and a `df`; it has no business taking longer. */
const PROBE_TIMEOUT_SEC = 15;

/** `GET /api/tracks/:id/vitals` */
export async function vitals(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  if (!ctx.sprites) return json({ data: out("no_token") });

  const fountain = requireFountain(ctx);
  const machine = await machineOf(fountain, project).catch(() => null);
  if (!machine) return json({ data: out("no_machine") });
  const spriteName = await spriteFor(fountain, machine.sandboxId);
  if (!spriteName) return json({ data: out("no_sprite") });

  try {
    const raw = await ctx.sprites.exec(spriteName, ["sh", "-lc", probe(track.workdir)], PROBE_TIMEOUT_SEC);
    // Reachable but illegible is its own answer: the readout renders nothing
    // rather than a row of dashes, because a line of dashes reads as a fault
    // and this is a machine that is working fine and merely private about it.
    return json({ data: { available: true, why: null, vitals: parseVitals(raw.stdout) } satisfies VitalsReport });
  } catch {
    // A machine that is asleep is the common case here, and it is not an
    // error — it wakes on the next turn. The readout simply goes away.
    return json({ data: out("unreachable") });
  }
}

function out(why: MachineUnreachable): VitalsReport {
  return { available: false, why, vitals: null };
}

/**
 * The script, which prints `key=value` lines and never fails.
 *
 * Every read is guarded, because a probe that exits non-zero on a kernel
 * missing one file would take the other five figures down with it. The two
 * CPU samples bracket a sleep and each carry a clock reading, so the server
 * divides by the interval that actually elapsed.
 *
 * `df` prints its mount point along with its numbers so the readout can name
 * the filesystem it measured rather than the directory it asked about — which
 * differ the moment a worktree is on a volume of its own.
 */
export function probe(workdir: string): string {
  return [
    `p() { printf '%s=%s\\n' "$1" "$2"; }`,
    `clock() { awk '{print $1}' /proc/uptime 2>/dev/null; }`,
    `cg() { awk '/^usage_usec /{print $2}' /sys/fs/cgroup/cpu.stat 2>/dev/null; }`,
    // user+nice+system+idle+iowait+irq+softirq, then the two idle fields. Host
    // wide inside a container, so it is only ever the fallback.
    `st() { awk '/^cpu /{print ($2+$3+$4+$5+$6+$7+$8), ($5+$6)}' /proc/stat 2>/dev/null; }`,
    `p t0 "$(clock)"; p cg0 "$(cg)"; p st0 "$(st)"`,
    `sleep ${SAMPLE}`,
    `p t1 "$(clock)"; p cg1 "$(cg)"; p st1 "$(st)"`,
    `p nproc "$(nproc 2>/dev/null)"`,
    `p cpumax "$(cat /sys/fs/cgroup/cpu.max 2>/dev/null)"`,
    `p memcur "$(cat /sys/fs/cgroup/memory.current 2>/dev/null)"`,
    `p memmax "$(cat /sys/fs/cgroup/memory.max 2>/dev/null)"`,
    `p meminfo "$(awk '/^MemTotal:|^MemAvailable:/{printf "%s ", $2}' /proc/meminfo 2>/dev/null)"`,
    `p df "$({ df -kP ${shq(workdir)} 2>/dev/null || df -kP / 2>/dev/null; } | awk 'NR==2{print $2, $3, $6}')"`,
  ].join("\n");
}

/**
 * The probe's output, as numbers.
 *
 * Exported and pure so `vitals.test.ts` can hold it against the output of real
 * kernels — a cgroup v2 container, a v1 one, and a box where half of it is
 * missing — which is the only way to be confident about a parser whose whole
 * job is tolerating absence.
 */
export function parseVitals(stdout: string): MachineVitals | null {
  const f = fields(stdout);

  // The allowance the CPU figure is a fraction *of*. A quota is the honest
  // denominator where there is one; without it, every core the box can see.
  const cpuCores = quotaCores(f.get("cpumax")) ?? num(f.get("nproc"));
  const elapsed = delta(f.get("t0"), f.get("t1"));

  let cpuBusy: number | null = null;
  const usec = delta(f.get("cg0"), f.get("cg1"));
  if (usec !== null && elapsed !== null && elapsed > 0 && cpuCores) {
    cpuBusy = clamp(usec / 1e6 / elapsed / cpuCores);
  } else {
    // No cgroup v2 accounting. `/proc/stat` inside a container is the host's,
    // which overstates a quiet neighbour and understates a busy one — but it
    // is the difference between a rough answer and none.
    const a = pair(f.get("st0"));
    const b = pair(f.get("st1"));
    if (a && b && b[0] > a[0]) cpuBusy = clamp((b[0] - a[0] - (b[1] - a[1])) / (b[0] - a[0]));
  }

  // Two pairs, and they are not mixed unless they have to be: the cgroup's
  // current-against-limit describes this container, `/proc/meminfo`'s
  // total-against-available describes the box, and one number from each would
  // describe neither.
  const cgUsed = num(f.get("memcur"));
  const cgTotal = f.get("memmax") === "max" ? null : num(f.get("memmax"));
  const [totalKb, availKb] = (f.get("meminfo") ?? "").split(/\s+/).filter(Boolean).map((v) => num(v));
  let memUsedBytes: number | null = null;
  let memTotalBytes: number | null = null;
  if (cgUsed !== null && cgTotal !== null) {
    memUsedBytes = cgUsed;
    memTotalBytes = cgTotal;
  } else if (totalKb != null && availKb != null) {
    memTotalBytes = totalKb * 1024;
    memUsedBytes = (totalKb - availKb) * 1024;
  } else if (totalKb != null) {
    // An uncapped cgroup on a kernel too old for `MemAvailable`. What this
    // container is using, against what the box has: the two halves come from
    // different places, and it is still the useful comparison.
    memTotalBytes = totalKb * 1024;
    memUsedBytes = cgUsed;
  }

  const [dfTotal, dfUsed, mount] = (f.get("df") ?? "").split(/\s+/).filter(Boolean);
  const diskTotalBytes = kb(dfTotal);
  const diskUsedBytes = kb(dfUsed);

  const v: MachineVitals = {
    cpuCores,
    cpuBusy,
    memUsedBytes,
    memTotalBytes,
    diskUsedBytes,
    diskTotalBytes,
    diskMount: mount ?? null,
  };
  // Nothing legible at all is not a reading with six holes in it. The readout
  // wants to know the difference so it can render nothing.
  return cpuCores === null && cpuBusy === null && memTotalBytes === null && diskTotalBytes === null ? null : v;
}

function fields(stdout: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of stdout.split("\n")) {
    const eq = line.indexOf("=");
    if (eq > 0) out.set(line.slice(0, eq).trim(), line.slice(eq + 1).trim());
  }
  return out;
}

/** A decimal, or null for anything that is not one — including "", "max" and "N". */
function num(text: string | undefined): number | null {
  if (!text) return null;
  const n = Number(text);
  return Number.isFinite(n) ? n : null;
}

function kb(text: string | undefined): number | null {
  const n = num(text);
  return n === null ? null : n * 1024;
}

/** Two counters, later minus earlier. Null if either is missing or it went backwards. */
function delta(a: string | undefined, b: string | undefined): number | null {
  const from = num(a);
  const to = num(b);
  if (from === null || to === null || to < from) return null;
  return to - from;
}

/** `"<total> <idle>"`, both numbers or nothing. */
function pair(text: string | undefined): [number, number] | null {
  const [a, b] = (text ?? "").split(/\s+/).filter(Boolean);
  const total = num(a);
  const idle = num(b);
  return total === null || idle === null ? null : [total, idle];
}

/**
 * `cpu.max` as a core count: `"200000 100000"` is two cores, `"max 100000"` is
 * no quota at all — which is a null here rather than a zero, so the caller
 * falls through to `nproc`.
 */
export function quotaCores(text: string | undefined): number | null {
  const [quota, period] = (text ?? "").split(/\s+/).filter(Boolean);
  const q = num(quota);
  const p = num(period);
  if (q === null || p === null || q <= 0 || p <= 0) return null;
  return q / p;
}

/** Sampling error and a rounded clock can put this a hair outside 0–1. */
function clamp(n: number): number | null {
  return Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : null;
}
