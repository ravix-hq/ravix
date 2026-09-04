/**
 * How much of the machine is left, in one dim line.
 *
 * This is deliberately the smallest thing on the screen. Nobody opens
 * switchyard to watch a gauge, and a project whose CPU is at 40% is not
 * telling you anything you needed to know. It exists for the half-hour a
 * month when it is the only thing you need: four tracks on one box share one
 * CPU allowance, one memory limit and one disk, and "is it me or is it the
 * box?" cannot otherwise be answered from inside the app.
 *
 * So it lives at the right-hand end of the dock's tab strip — beside Setup,
 * Run and Terminal, which are the other three things about the machine rather
 * than about the conversation — and it renders **nothing at all** when there
 * are no numbers. A deployment without a Sprites token, a machine that has
 * gone to sleep, a kernel whose cgroup files are somewhere else: all of them
 * are a line that is not there, not a row of dashes. The dashes would read as
 * a fault on a machine that is working perfectly well.
 *
 * The figures are the *machine's*, not the track's. Every track on the project
 * shows the same three numbers, which is the point of showing them.
 */
import { useEffect, useState } from "react";
import type { MachineVitals, Track, VitalsReport } from "../../shared/api";
import { api } from "../lib/api";

/**
 * How often to ask.
 *
 * Each read is an exec on the box — cheap, but not free, and out of band from
 * the agent's turns the same way the terminal is. Twenty seconds is slow
 * enough to be invisible in the logs and fast enough that a build which has
 * been eating the disk for a minute has already shown up here.
 */
const PERIOD_MS = 20_000;

/** Past this, the figure is the reason something is slow rather than a detail. */
const HOT = 0.9;

export function Vitals({ track }: { track: Track }) {
  const [report, setReport] = useState<VitalsReport | null>(null);

  useEffect(() => {
    let live = true;
    const read = () => {
      // A background tab polling a machine it is not being read on is the
      // exact cost this readout is not worth paying. It catches up on the
      // visibility change, which is the moment somebody looks at it again.
      if (document.hidden) return;
      api.vitals(track.id).then(
        (r) => live && setReport(r),
        // A failed read is not worth a toast: the line goes away and comes
        // back on the next tick, which is all this is for.
        () => live && setReport(null),
      );
    };
    read();
    const timer = setInterval(read, PERIOD_MS);
    document.addEventListener("visibilitychange", read);
    return () => {
      live = false;
      clearInterval(timer);
      document.removeEventListener("visibilitychange", read);
    };
  }, [track.id]);

  const v = report?.vitals;
  if (!v) return null;

  const cpu = v.cpuBusy;
  const mem = ratio(v.memUsedBytes, v.memTotalBytes);
  const disk = ratio(v.diskUsedBytes, v.diskTotalBytes);
  const parts: { key: string; label: string; text: string; hot: boolean }[] = [];
  if (cpu !== null) parts.push({ key: "cpu", label: "cpu", text: percent(cpu), hot: cpu >= HOT });
  if (v.memTotalBytes !== null) {
    parts.push({ key: "mem", label: "ram", text: amount(v.memUsedBytes, v.memTotalBytes), hot: mem !== null && mem >= HOT });
  }
  if (v.diskTotalBytes !== null) {
    parts.push({ key: "disk", label: "disk", text: amount(v.diskUsedBytes, v.diskTotalBytes), hot: disk !== null && disk >= HOT });
  }
  if (!parts.length) return null;

  return (
    <span className="vitals" title={sentence(v)}>
      {parts.map((p) => (
        // The separators are the stylesheet's, not this list's: a `·` between
        // items is a thing the eye needs and the reader does not, and a
        // middot in the markup is one the screen reader would announce
        // between every pair of numbers.
        <span key={p.key}>
          {p.label}
          <b className={p.hot ? "hot" : undefined}>{p.text}</b>
        </span>
      ))}
    </span>
  );
}

/**
 * The whole reading, spelled out, for the hover and the screen reader.
 *
 * The strip has room for `ram 1.4/4G` and not for what that means, so the
 * units, the denominator and the fact that this is shared go here rather than
 * being left to be inferred from an abbreviation.
 */
function sentence(v: MachineVitals): string {
  const said: string[] = [];
  if (v.cpuBusy !== null) {
    said.push(v.cpuCores !== null ? `${percent(v.cpuBusy)} of ${cores(v.cpuCores)} in use` : `${percent(v.cpuBusy)} CPU in use`);
  }
  if (v.memTotalBytes !== null) said.push(`${full(v.memUsedBytes)} of ${full(v.memTotalBytes)} memory`);
  if (v.diskTotalBytes !== null) {
    said.push(`${full(v.diskUsedBytes)} of ${full(v.diskTotalBytes)} on ${v.diskMount ?? "disk"}`);
  }
  return `This project's machine: ${said.join(", ")}. Shared by every track on it.`;
}

function ratio(used: number | null, total: number | null): number | null {
  return used === null || total === null || total <= 0 ? null : used / total;
}

function percent(n: number): string {
  return `${Math.round(n * 100)}%`;
}

function cores(n: number): string {
  const shown = Number.isInteger(n) ? `${n}` : n.toFixed(1);
  return `${shown} core${n === 1 ? "" : "s"}`;
}

/** `1.4/4G` — one unit for the pair, because two would be a paragraph. */
function amount(used: number | null, total: number | null): string {
  if (total === null) return used === null ? "" : gib(used);
  return used === null ? gib(total) : `${gib(used, false)}/${gib(total)}`;
}

function gib(bytes: number, unit = true): string {
  const g = bytes / 1024 ** 3;
  const shown = g >= 10 ? `${Math.round(g)}` : g >= 0.1 ? g.toFixed(1) : g.toFixed(2);
  return unit ? `${shown}G` : shown;
}

function full(bytes: number | null): string {
  return bytes === null ? "an unknown amount" : `${gib(bytes, false)} GB`;
}
