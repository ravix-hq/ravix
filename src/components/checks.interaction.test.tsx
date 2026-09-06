import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ChecksReport, Project, Track } from "../../shared/api";
import { api } from "../lib/api";
import { Checks } from "./Checks";

let createRoot: (element: HTMLElement) => Root;
beforeAll(async () => {
  GlobalRegistrator.register({ url: "http://localhost/" });
  (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
  ({ createRoot } = await import("react-dom/client"));
});
afterAll(async () => {
  delete (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT;
  await GlobalRegistrator.unregister();
});

const project = { repo: "managoat/demos" } as Project;
const track = (id: string) => ({ id, branch: `jhgaylor/${id}`, title: id }) as Track;
const report = (id: string, number: number | null): ChecksReport => ({
  ref: `jhgaylor/${id}`, sha: number ? "abc123" : null, pushed: number !== null,
  runs: number ? [{ name: "previous-track-ci", status: "completed", conclusion: "success", url: null, startedAt: null, completedAt: null }] : [],
  pull: number ? { number, title: "Previous track PR", author: null, headRef: `jhgaylor/${id}`, baseRef: "main", draft: false, updatedAt: "", state: "merged" } : null,
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return { promise, resolve };
}

test("switching tracks hides the old PR and checks while loading and ignores its late refresh", async () => {
  const refresh = deferred<ChecksReport>();
  const antwerp = deferred<ChecksReport>();
  const checks = spyOn(api, "checks")
    .mockResolvedValueOnce(report("old", 27))
    .mockImplementationOnce(() => refresh.promise)
    .mockImplementationOnce(() => antwerp.promise);
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const render = (id: string) => root.render(<Checks track={track(id)} project={project} capabilities={{ github: true, exec: false, vaults: false }} />);
  try {
    await act(async () => render("old"));
    expect(element.textContent).toContain("#27");
    const button = [...element.querySelectorAll("button")].find(b => b.textContent === "Refresh")!;
    await act(async () => button.click());
    await act(async () => render("antwerp"));
    expect(checks).toHaveBeenLastCalledWith("antwerp");
    expect(element.textContent).not.toContain("#27");
    expect(element.textContent).not.toContain("previous-track-ci");
    await act(async () => refresh.resolve(report("old", 28)));
    expect(element.textContent).not.toContain("#28");
    await act(async () => antwerp.resolve(report("antwerp", null)));
    expect(element.textContent).toContain("Nothing pushed yet");
    expect(element.textContent).not.toContain("Previous track PR");
  } finally {
    await act(async () => root.unmount());
    element.remove(); checks.mockRestore();
  }
});

test("a PR opened in one track does not override the next track's report", async () => {
  const oldReport = { ...report("old", null), pushed: true, sha: "abc123" };
  const checks = spyOn(api, "checks").mockImplementation(async id => id === "old" ? oldReport : report(id, null));
  const openPull = spyOn(api, "openPull").mockResolvedValue({ ...report("old", 27).pull!, url: "https://github.com/managoat/demos/pull/27" });
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const render = (id: string) => root.render(<Checks track={track(id)} project={project} capabilities={{ github: true, exec: false, vaults: false }} />);
  try {
    await act(async () => render("old"));
    const button = [...element.querySelectorAll("button")].find(b => b.textContent === "Open a draft pull request")!;
    await act(async () => button.click());
    expect(element.textContent).toContain("#27");
    await act(async () => render("antwerp"));
    expect(element.textContent).toContain("Nothing pushed yet");
    expect(element.textContent).not.toContain("#27");
  } finally {
    await act(async () => root.unmount());
    element.remove(); checks.mockRestore(); openPull.mockRestore();
  }
});
