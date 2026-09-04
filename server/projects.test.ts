import { expect, test } from "bun:test";
import { pickRuntime } from "./projects";

/**
 * The model id is the one field on `POST /api/agents` that Fountain validates
 * with a regex — `^[a-z0-9_-]+/[a-z0-9._-]+$` — and it is set once, at project
 * creation, by code nobody reads again. A wrong default here does not fail a
 * typecheck, a test that never asserts on it, or a catalog call that happens
 * to succeed. It fails on somebody's first project, as a 422.
 */

test("the default is provider-prefixed, the way Fountain writes them", () => {
  const { model } = pickRuntime(null);
  expect(model).toMatch(/^[a-z0-9_-]+\/[a-z0-9._-]+$/);
});

test("the catalog wins over the default when it offers the same model", () => {
  const catalog = { runtimes: ["claude", "codex"], models: { claude: ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"] } };
  expect(pickRuntime(catalog)).toEqual({ runtime: "claude", model: "anthropic/claude-opus-5" });
});

test("a Fountain without our preferred model still yields a usable one", () => {
  // The point of the fallback: a deployment should get a machine rather than
  // an error about a model nobody asked for.
  const noOpus = { runtimes: ["claude"], models: { claude: ["anthropic/claude-sonnet-5"] } };
  expect(pickRuntime(noOpus).model).toBe("anthropic/claude-sonnet-5");

  const otherOpus = { runtimes: ["claude"], models: { claude: ["vendor/opus-9"] } };
  expect(pickRuntime(otherOpus).model).toBe("vendor/opus-9");
});

test("a Fountain without our preferred runtime falls to its first", () => {
  const noClaude = { runtimes: ["codex"], models: { codex: ["openai/gpt-5"] } };
  expect(pickRuntime(noClaude)).toEqual({ runtime: "codex", model: "openai/gpt-5" });
});

test("an empty catalog is not a crash", () => {
  expect(pickRuntime({ runtimes: [], models: {} }).runtime).toBe("claude");
});
