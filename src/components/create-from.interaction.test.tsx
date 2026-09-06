import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { Project, Track } from "../../shared/api";
import { api } from "../lib/api";
import { CreateFrom } from "./CreateFrom";

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

test("quick creation has a name, defers repository loading, and prevents duplicate submissions", async () => {
  const branches = spyOn(api, "branches").mockResolvedValue([]);
  let resolve!: (track: Track) => void;
  const open = spyOn(api, "openTrack").mockImplementation(() => new Promise(done => { resolve = done; }));
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  let opened: Track | undefined;
  try {
    await act(async () => root.render(<CreateFrom project={{ id: "p1", repo: "org/repo", defaultBranch: "main" } as Project}
      onClose={() => {}} onOpen={track => { opened = track; }} />));
    const input = element.querySelector("input")!;
    expect(input.value.length).toBeGreaterThan(0);
    expect(document.activeElement).toBe(input);
    expect(element.textContent).toContain("New worktree from main.");
    expect(element.querySelector('[role="listbox"]')).toBeNull();
    expect(branches).not.toHaveBeenCalled();
    const title = input.value;
    await act(async () => {
      element.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      element.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    });
    expect(open).toHaveBeenCalledTimes(1);
    expect(open).toHaveBeenCalledWith("p1", { title, origin: { kind: "blank" } });
    await act(async () => resolve({ id: "created" } as Track));
    expect(opened?.id).toBe("created");
  } finally {
    await act(async () => root.unmount());
    element.remove(); branches.mockRestore(); open.mockRestore();
  }
});
