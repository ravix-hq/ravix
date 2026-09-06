import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { Track } from "../../shared/api";
import { ApiError, api } from "../lib/api";
import { Changes, useDiff } from "./Changes";
import { Files } from "./Files";
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
const asleep = () => new ApiError(409, "machine_asleep", "Wake with agent sends a short turn to resume it.");
function Diff({ id }: { id: string }) { return <Changes diff={useDiff(id)} />; }
function wakeButton(element: HTMLElement) {
  return [...element.querySelectorAll("button")].find(b => b.textContent === "Wake with agent");
}
test("changes wake on a click and never replay that click on track navigation", async () => {
  const diff = spyOn(api, "diff").mockImplementation(async () => { throw asleep(); });
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  try {
    await act(async () => root.render(<Diff id="first" />));
    expect(diff).toHaveBeenLastCalledWith("first", false);
    await act(async () => wakeButton(element)!.click());
    expect(diff).toHaveBeenLastCalledWith("first", true);
    await act(async () => root.render(<Diff id="second" />));
    expect(diff).toHaveBeenLastCalledWith("second", false);
    await act(async () => root.render(<Diff id="first" />));
    expect(diff).toHaveBeenLastCalledWith("first", false);
    expect(diff.mock.calls.filter(([, wake]) => wake)).toHaveLength(1);
  } finally {
    await act(async () => root.unmount());
    element.remove(); diff.mockRestore();
  }
});
test("files explicitly wake their own track and show the directory afterward", async () => {
  const files = spyOn(api, "files").mockImplementation(async (_id, path, wake) => {
    if (!wake) throw asleep();
    return { path: path!, entries: [], truncated: false };
  });
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  try {
    await act(async () => root.render(<Files track={{ id: "files", workdir: "/home/sprite/work/files" } as Track} />));
    expect(files).toHaveBeenLastCalledWith("files", "/home/sprite/work/files", false);
    await act(async () => wakeButton(element)!.click());
    expect(files).toHaveBeenLastCalledWith("files", "/home/sprite/work/files", true);
    expect(wakeButton(element)).toBeUndefined();
  } finally {
    await act(async () => root.unmount());
    element.remove(); files.mockRestore();
  }
});
