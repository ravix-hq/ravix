import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import { api } from "../lib/api";
import { TrackView, type TrackViewProps } from "./TrackView";

let createRoot: (element: HTMLElement) => Root;
let source: EventTarget;
const originalSource = globalThis.EventSource;
beforeAll(async () => {
  GlobalRegistrator.register({ url: "http://localhost/" });
  (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT = true;
  globalThis.EventSource = class extends EventTarget {
    constructor() { super(); source = this; }
    close() {}
  } as unknown as typeof EventSource;
  ({ createRoot } = await import("react-dom/client"));
});
afterAll(async () => {
  globalThis.EventSource = originalSource;
  delete (globalThis as Record<string, unknown>).IS_REACT_ACT_ENVIRONMENT;
  await GlobalRegistrator.unregister();
});

test.each(["turn start", "queue removal"])("%s reveals a prompt before any reply, retrying delayed persistence", async (trigger) => {
  let persisted = false;
  const events = spyOn(api, "events").mockImplementation(async () => ({ events: [], turns: persisted ? [{ id: "turn", prompt: "Show this released prompt", origin: "user", status: "running", insertedAt: "2026-09-06T12:00:00Z" }] : [] }));
  const queue = spyOn(api, "promptQueue").mockResolvedValue([]);
  if (trigger === "queue removal") queue.mockResolvedValueOnce([{ id: "saved", prompt: "Queued instruction", status: "sending" }] as never);
  const preview = spyOn(api, "preview").mockResolvedValue(null as never);
  const beacon = spyOn(navigator, "sendBeacon").mockReturnValue(true);
  const presence = spyOn(api, "presence").mockResolvedValue({ ok: true } as never);
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const props = {
    project: { runtime: "claude" },
    track: { id: "track", status: "ready", origin: { kind: "branch" }, people: [], workdir: "/work", slug: "test" },
    header: {}, starters: [], capabilities: {}, present: [], viewerLogin: "viewer",
    onError: () => {}, onOpenSettings: () => {}, onActivity: () => {},
  } as unknown as TrackViewProps;
  try {
    await act(async () => root.render(<TrackView {...props} />));
    const before = events.mock.calls.length;
    if (trigger === "queue removal") await act(async () => { await Bun.sleep(2100); });
    else await act(async () => source.dispatchEvent(new MessageEvent("stage", { data: JSON.stringify({ id: 1, kind: "stage", stage: "turn", state: "started" }) })));
    expect(events.mock.calls.length).toBeGreaterThan(before);
    expect(element.textContent).not.toContain("Show this released prompt");
    persisted = true;
    await act(async () => { await Bun.sleep(1100); });
    expect(element.textContent).toContain("Show this released prompt");
  } finally {
    await act(async () => root.unmount());
    element.remove();
    events.mockRestore(); queue.mockRestore(); presence.mockRestore(); beacon.mockRestore(); preview.mockRestore();
  }
});
