import { afterAll, beforeAll, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import { Transcript } from "./Transcript";

let createRoot: (element: HTMLElement) => Root;
beforeAll(async () => {
  GlobalRegistrator.register({ url: "https://localhost/" });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  ({ createRoot } = await import("react-dom/client"));
});
afterAll(async () => {
  await GlobalRegistrator.unregister();
});

test("copies the selected block verbatim and reports clipboard failure", async () => {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const copied: string[] = [];
  const original = navigator.clipboard.writeText;
  navigator.clipboard.writeText = async (text) => { copied.push(text); };
  const body = '```ts\n  const x = "<tag>&";\n\n  next();\n```\n\n```\nsecond\n```';
  try {
    await act(async () => root.render(<Transcript trackId="track" turns={[]} runtime="codex" workdir="/work" running={false} events={[{
      id: 1, kind: "output", stream: "acp", stage: null, state: null, turn_id: null,
      ts: "2026-09-06T12:00:00Z",
      data: JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { update: {
        sessionUpdate: "agent_message_chunk", content: { type: "text", text: body },
      } } }),
    }]} />));
    const buttons = element.querySelectorAll<HTMLButtonElement>(".code-copy");
    expect(buttons.length).toBe(2);
    await act(async () => buttons[0]!.click());
    expect(copied).toEqual(['  const x = "<tag>&";\n\n  next();']);
    expect(buttons[0]!.textContent).toBe("Copied!");
    expect(buttons[1]!.textContent).toBe("Copy");
    navigator.clipboard.writeText = async () => { throw new Error("Denied"); };
    await act(async () => buttons[1]!.click());
    expect(buttons[1]!.textContent).toBe("Copy failed");
    expect(buttons[1]!.disabled).toBe(false);
  } finally {
    navigator.clipboard.writeText = original;
    await act(async () => root.unmount());
    element.remove();
  }
});

test("keeps selected reply nodes during streaming and flushes after selection clears", async () => {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const render = (text: string) => <Transcript trackId="selection" turns={[]} runtime="codex" running events={[{
    id: text.length, kind: "output", stream: "acp", stage: null, state: null, turn_id: null,
    ts: "2026-09-06T12:00:00Z",
    data: JSON.stringify({ jsonrpc: "2.0", method: "session/update", params: { update: {
      sessionUpdate: "agent_message_chunk", content: { type: "text", text },
    } } }),
  }]} />;
  try {
    await act(async () => root.render(render("First words")));
    const paragraph = element.querySelector(".md p")!;
    const range = document.createRange();
    range.selectNodeContents(paragraph);
    const selection = document.getSelection()!;
    selection.addRange(range);
    await act(async () => root.render(render("First words and more")));
    expect(element.querySelector(".md p")).toBe(paragraph);
    expect(selection.toString()).toBe("First words");
    expect(paragraph.textContent).toBe("First words");
    selection.removeAllRanges();
    await act(async () => document.dispatchEvent(new Event("selectionchange")));
    expect(element.querySelector(".md p")!.textContent).toBe("First words and more");
    const updated = element.querySelector(".md p");
    await act(async () => root.render(render("First words and more")));
    expect(element.querySelector(".md p")).toBe(updated);
  } finally {
    document.getSelection()?.removeAllRanges();
    await act(async () => root.unmount());
    element.remove();
  }
});
