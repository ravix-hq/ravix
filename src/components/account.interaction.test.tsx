import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import { api, ApiError } from "../lib/api";
import { NewProject } from "./NewProject";

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

test("a rejected GitHub token offers a fresh sign-in attempt instead of an empty repository list", async () => {
  const repos = spyOn(api, "repos").mockRejectedValue(new ApiError(401, "reauthenticate", "Sign in again to load your repositories."));
  const session = spyOn(api, "session").mockResolvedValue({ viewer: null, signInUrl: "https://github.test/login?state=fresh", installUrl: "", capabilities: { github: true, exec: false, vaults: false } });
  const navigate = spyOn(window.location, "assign").mockImplementation(() => {});
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  try {
    await act(async () => root.render(<NewProject onCreated={() => {}} onClose={() => {}} />));
    // Dialog content is portalled into the document body.
    const dialog = document.querySelector('[role="dialog"]')!;
    expect(dialog.textContent).toContain("Sign in again to load your repositories.");
    expect(dialog.textContent).not.toContain("Nothing matches");
    expect(dialog.textContent).not.toContain("Add another account");
    expect(session).not.toHaveBeenCalled();
    const button = [...dialog.querySelectorAll("button")].find(b => b.textContent === "Sign in again")!;
    await act(async () => button.click());
    expect(session).toHaveBeenCalledTimes(1);
    expect(navigate).toHaveBeenCalledWith("https://github.test/login?state=fresh");
    expect(button.disabled).toBe(true);
  } finally {
    await act(async () => root.unmount());
    element.remove(); repos.mockRestore(); session.mockRestore(); navigate.mockRestore();
  }
});
