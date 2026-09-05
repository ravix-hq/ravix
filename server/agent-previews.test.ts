import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { agentPreviewScript } from "./agent-previews";
import { AGENT_PREVIEW_START, AGENT_PREVIEW_END, visiblePreviewPrompt } from "../shared/previews";
import { splitAuthor } from "../shared/author";

test("the actual shell helper preserves command JSON and authenticates without printing its credential", async () => {
  const dir = mkdtempSync(join(tmpdir(), "sy-agent-helper-"));
  const calls: unknown[] = [];
  const token = "test-agent-capability-not-a-provider-token";
  const server = Bun.serve({ port: 0, async fetch(req) {
    expect(req.headers.get("authorization")).toBe(`Bearer ${token}`);
    const body = await req.json(); calls.push(body);
    return Response.json({ data: { state: "stopped" } });
  } });
  try {
    const path = join(dir, "preview.sh");
    writeFileSync(path, agentPreviewScript(`http://localhost:${server.port}/api/tracks/t1/preview/agent`, token), { mode: 0o600 });
    const config = { directory: "apps/it's web", command: 'npm run dev -- --port "$PORT"; echo "$(literal)"', readinessPath: "/" };
    for (const args of [["configure", JSON.stringify(config)], ["status"], ["configure", "null"]]) {
      const child = Bun.spawn(["sh", path, ...args], { stdout: "pipe", stderr: "pipe" });
      const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(code).toBe(0); expect(stdout).not.toContain(token); expect(stderr).toBe("");
    }
    expect(calls).toEqual([{ action: "configure", config }, { action: "status" }, { action: "configure", config: null }]);
    const invalid = Bun.spawn(["sh", path, "arbitrary-endpoint"], { stdout: "ignore", stderr: "ignore" });
    expect(await invalid.exited).toBe(2); expect(calls).toHaveLength(3);
  } finally { server.stop(true); rmSync(dir, { recursive: true, force: true }); }
});

test("tool instructions are removed for display while the user's words and author remain intact", () => {
  const original = "[from @ana] Configure my preview\nthen show the result";
  const wrapped = `${AGENT_PREVIEW_START}\ninternal instructions\n${AGENT_PREVIEW_END}\n\n${original}`;
  expect(visiblePreviewPrompt(wrapped)).toBe(original);
  expect(splitAuthor(visiblePreviewPrompt(wrapped))).toEqual({ login: "ana", text: "Configure my preview\nthen show the result" });
  expect(visiblePreviewPrompt(original)).toBe(original);
  const incomplete = `${AGENT_PREVIEW_START}\nordinary unfinished text`;
  expect(visiblePreviewPrompt(incomplete)).toBe(incomplete);
});
