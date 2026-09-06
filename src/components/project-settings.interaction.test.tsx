import { afterAll, beforeAll, expect, spyOn, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { Project } from "../../shared/api";
import { api } from "../lib/api";
import { ProjectSettings } from "./ProjectSettings";
let createRoot: (element: HTMLElement) => Root;
beforeAll(async () => {
  GlobalRegistrator.register({ url: "https://localhost/" });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  ({ createRoot } = await import("react-dom/client"));
});
afterAll(async () => { await GlobalRegistrator.unregister(); });
test("harness selection filters models and saves the chosen pair", async () => {
  const settings = spyOn(api, "settings").mockResolvedValue({ name: "Project", runtime: "claude", model: "anthropic/opus", instructions: "", setupScript: "", packages: {}, envKeys: [], vaultKeys: [], catalog: { runtimes: ["claude", "codex"], models: { claude: ["anthropic/opus"], codex: ["openai/one", "openai/two"] } } });
  const preview = spyOn(api, "previewDefaults").mockResolvedValue(null);
  const save = spyOn(api, "saveSettings").mockResolvedValue({ rev: 2 });
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  try {
    await act(async () => root.render(<ProjectSettings project={{ id: "p", name: "Project", runtime: "claude", model: "anthropic/opus" } as Project} onClose={() => {}} />));
    const harness = element.querySelector<HTMLSelectElement>("#sy-runtime")!;
    const model = element.querySelector<HTMLSelectElement>("#sy-model")!;
    expect(model.tagName).toBe("SELECT");
    await act(async () => { harness.value = "codex"; harness.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(Array.from(model.options, option => option.value)).toEqual(["openai/one", "openai/two"]);
    expect(model.value).toBe("openai/one");
    await act(async () => { model.value = "openai/two"; model.dispatchEvent(new Event("change", { bubbles: true })); });
    const button = Array.from(element.querySelectorAll("button")).find(button => button.textContent === "Save changes")!;
    await act(async () => button.click());
    expect(save).toHaveBeenCalledWith("p", { name: "Project", instructions: "", runtime: "codex", model: "openai/two" });
  } finally {
    await act(async () => root.unmount());
    element.remove(); settings.mockRestore(); preview.mockRestore(); save.mockRestore();
  }
});
