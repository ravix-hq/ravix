/** Machine-wide usage, polled only while the machine stats pane is open. */
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
  const [loading, setLoading] = useState(true);
  const [report, setReport] = useState<VitalsReport | null>(null);

  useEffect(() => {
    let live = true;
    const read = () => {
      // A background tab polling a machine it is not being read on is the
      // exact cost this readout is not worth paying. It catches up on the
      // visibility change, which is the moment somebody looks at it again.
      if (document.hidden) return;
      api.vitals(track.id).then(
        (r) => { if (live) { setReport(r); setLoading(false); } },
        // Keep failures local to the pane and retry on the next tick.
        () => { if (live) { setReport(null); setLoading(false); } },
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
  if (!v) return <div className="machine-stats" role="status">{loading ? "Loading machine stats…" : "Machine stats are currently unavailable."}</div>;

  const cpu = v.cpuBusy;
  const mem = ratio(v.memUsedBytes, v.memTotalBytes);
  const disk = ratio(v.diskUsedBytes, v.diskTotalBytes);
  const parts: { key: string; label: string; text: string; hot: boolean }[] = [];
  if (cpu !== null) parts.push({ key: "cpu", label: "CPU", text: percent(cpu), hot: cpu >= HOT });
  if (v.memTotalBytes !== null) {
    parts.push({ key: "mem", label: "RAM", text: amount(v.memUsedBytes, v.memTotalBytes), hot: mem !== null && mem >= HOT });
  }
  if (v.diskTotalBytes !== null) {
    parts.push({ key: "disk", label: "Disk", text: amount(v.diskUsedBytes, v.diskTotalBytes), hot: disk !== null && disk >= HOT });
  }
  return (
    <section className="machine-stats" aria-label="Machine stats">
      <p>Shared by every track on this machine.</p>
      {parts.length ? (
        <dl className="vitals" title={sentence(v)}>
          {parts.map((p) => (
            <div key={p.key}>
              <dt>{p.label}</dt>
              <dd className={p.hot ? "hot" : undefined}>{p.text}</dd>
            </div>
          ))}
        </dl>
      ) : <p role="status">Machine stats are currently unavailable.</p>}
    </section>
  );
}

/** Expanded machine usage for the hover description. */
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
