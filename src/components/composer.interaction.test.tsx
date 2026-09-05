import { afterAll, beforeAll, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import { Composer } from "./Composer";

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

test("a busy composer immediately submits every follow-up, with Send and Stop both available", async () => {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const sent: string[] = [];
  let stops = 0;
  try {
    await act(async () => root.render(<Composer running model="test" onSend={async (text) => { sent.push(text); }} onInterrupt={() => { stops++; }} />));
    const input = element.querySelector("textarea")!;
    const setValue = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!;
    for (const prompt of ["Run the tests next", "Then summarize the changes"]) {
      await act(async () => {
        setValue.call(input, prompt);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
      await act(async () => (element.querySelector('[aria-label="Send"]') as HTMLButtonElement).click());
    }
    expect(sent).toEqual(["Run the tests next", "Then summarize the changes"]);
    expect(input.value).toBe("");
    await act(async () => (element.querySelector('[aria-label="Stop this turn"]') as HTMLButtonElement).click());
    expect(stops).toBe(1);
    await act(async () => root.unmount());
    expect(sent).toHaveLength(2);
  } finally {
    await act(async () => root.unmount());
    element.remove();
  }
});

test("an unacknowledged prompt returns to the composer instead of appearing saved", async () => {
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  try {
    await act(async () => root.render(<Composer running model="test" onSend={async () => { throw new Error("offline"); }} onInterrupt={() => {}} />));
    const input = element.querySelector("textarea")!;
    await act(async () => {
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(input, "Keep my instruction");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await act(async () => (element.querySelector('[aria-label="Send"]') as HTMLButtonElement).click());
    expect(input.value).toBe("Keep my instruction");
  } finally {
    await act(async () => root.unmount());
    element.remove();
  }
});
