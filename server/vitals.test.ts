import { expect, test } from "bun:test";
import { parseVitals, probe, quotaCores } from "./vitals";

/** What the probe prints on a cgroup v2 container with a two-core quota. */
const CGROUP_V2 = [
  "t0=1200.50",
  "cg0=4000000",
  "st0=900000 700000",
  "t1=1200.80",
  // 300ms elapsed, 300ms of CPU burned: one core of the two, so 50%.
  "cg1=4300000",
  "st1=900300 700200",
  "nproc=8",
  "cpumax=200000 100000",
  "memcur=1073741824",
  "memmax=4294967296",
  "meminfo=16384000 12288000 ",
  "df=52428800 10485760 /",
].join("\n");

test("a cgroup v2 box reports its quota, not the cores it can see", () => {
  const v = parseVitals(CGROUP_V2)!;
  expect(v.cpuCores).toBe(2);
  expect(v.cpuBusy).toBeCloseTo(0.5, 5);
});

test("memory is the cgroup's own pair when the cgroup has a limit", () => {
  // Not `/proc/meminfo`'s 16 GB: the container may have 4, and the number that
  // decides whether the next `bun install` is killed is the container's.
  const v = parseVitals(CGROUP_V2)!;
  expect(v.memUsedBytes).toBe(1024 * 1024 * 1024);
  expect(v.memTotalBytes).toBe(4 * 1024 * 1024 * 1024);
});

test("disk comes back with the mount point it was actually measured on", () => {
  const v = parseVitals(CGROUP_V2)!;
  expect(v.diskTotalBytes).toBe(52428800 * 1024);
  expect(v.diskUsedBytes).toBe(10485760 * 1024);
  expect(v.diskMount).toBe("/");
});

test("no quota falls through to every core the box can see", () => {
  const v = parseVitals(["nproc=4", "cpumax=max 100000", "t0=10.00", "t1=10.50", "cg0=0", "cg1=1000000"].join("\n"))!;
  expect(v.cpuCores).toBe(4);
  // One core-second of CPU in half a second is two cores of four: 50%.
  expect(v.cpuBusy).toBeCloseTo(0.5, 5);
});

test("uncapped memory uses /proc/meminfo's pair rather than mixing the two", () => {
  const v = parseVitals(["memcur=1073741824", "memmax=max", "meminfo=8192000 6144000 "].join("\n"))!;
  expect(v.memTotalBytes).toBe(8192000 * 1024);
  expect(v.memUsedBytes).toBe(2048000 * 1024);
});

test("without cgroup cpu accounting it falls back to /proc/stat", () => {
  // 1000 ticks passed, 250 of them idle.
  const v = parseVitals(["t0=1.00", "t1=1.30", "st0=10000 8000", "st1=11000 8250", "nproc=2"].join("\n"))!;
  expect(v.cpuBusy).toBeCloseTo(0.75, 5);
});

test("a figure that could not be read is absent, never zero", () => {
  // The kernel has no cgroup files and `df` was refused. Saying 0% CPU and an
  // empty disk here would be a confident lie about a machine that is fine.
  const v = parseVitals(["nproc=4", "cpumax=", "memcur=", "memmax=", "meminfo=", "df="].join("\n"))!;
  expect(v.cpuCores).toBe(4);
  expect(v.cpuBusy).toBeNull();
  expect(v.memTotalBytes).toBeNull();
  expect(v.memUsedBytes).toBeNull();
  expect(v.diskTotalBytes).toBeNull();
  expect(v.diskMount).toBeNull();
});

test("nothing legible at all is null, not a reading full of holes", () => {
  expect(parseVitals("")).toBeNull();
  expect(parseVitals("sh: 1: nproc: not found\n")).toBeNull();
});

test("a counter that went backwards is dropped rather than read as a spike", () => {
  // The box restarted between samples: `/proc/uptime` and the cgroup counters
  // both reset, and the difference is negative rather than enormous.
  const v = parseVitals(["nproc=2", "t0=900.00", "t1=1.00", "cg0=5000000", "cg1=10"].join("\n"))!;
  expect(v.cpuBusy).toBeNull();
});

test("a busybox clock that prints something other than a number is not a division", () => {
  const v = parseVitals(["nproc=2", "t0=", "t1=", "cg0=0", "cg1=600000"].join("\n"))!;
  expect(v.cpuBusy).toBeNull();
});

test("cpu.max reads as cores, and 'max' is no quota rather than none", () => {
  expect(quotaCores("200000 100000")).toBe(2);
  expect(quotaCores("50000 100000")).toBe(0.5);
  expect(quotaCores("max 100000")).toBeNull();
  expect(quotaCores("")).toBeNull();
  expect(quotaCores(undefined)).toBeNull();
});

// ── the probe, run for real ────────────────────────────────────────────

test("the workdir reaches df quoted, so a path cannot become a command", () => {
  // Slugs are validated long before here, but this string is interpolated into
  // a shell script that runs on the machine and the quoting is the only thing
  // between the two.
  const script = probe("/home/sprite/work/x'; touch /tmp/pwned; '");
  expect(script).toContain(`df -kP '/home/sprite/work/x'\\''; touch /tmp/pwned; '\\'''`);
  expect(script).not.toContain("; touch /tmp/pwned; '\n");
});

test("the probe runs on this machine and parses into numbers", () => {
  // The tests above are fixtures of kernels this suite cannot run. This one is
  // the opposite check, and the only one that would catch a typo in the awk: a
  // real box has to come back legible and quiet. `df` is the assertion because
  // it is the one figure POSIX guarantees — the rest are Linux, and this test
  // has to pass on a laptop as well as in the container it ships to.
  const run = Bun.spawnSync(["sh", "-lc", probe(process.cwd())]);
  expect(run.stderr.toString()).toBe("");
  const v = parseVitals(run.stdout.toString());
  expect(v).not.toBeNull();
  expect(v!.diskTotalBytes).toBeGreaterThan(0);
  expect(v!.diskUsedBytes).toBeGreaterThan(0);
  if (process.platform === "linux") expect(v!.cpuCores).toBeGreaterThan(0);
});

test("a CPU reading past its allowance is clamped rather than shown above 100%", () => {
  // Both samples are rounded to a hundredth of a second, so a genuinely
  // saturated box lands slightly over one every few reads.
  const v = parseVitals(["nproc=1", "cpumax=100000 100000", "t0=1.00", "t1=1.30", "cg0=0", "cg1=310000"].join("\n"))!;
  expect(v.cpuBusy).toBe(1);
});
