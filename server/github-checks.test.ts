import { expect, spyOn, test } from "bun:test";
import { GitHub, GitHubError } from "./github";

test("a merged PR survives deletion of its head branch", async () => {
  const gh = new GitHub({ appId: "1", slug: "test", clientId: "test", clientSecret: "test", privateKeyPem: "", webhookSecret: null, apiUrl: "https://api.github.com", webUrl: "https://github.com" });
  const token = spyOn(gh, "installationToken").mockResolvedValue("test");
  const paths: string[] = [];
  const transport = gh as unknown as { request(method: string, path: string): Promise<unknown> };
  const request = spyOn(transport, "request").mockImplementation(async (_, path) => {
    paths.push(path);
    if (path.includes("/branches/")) throw new GitHubError(404, "Not Found");
    if (path.includes("/pulls?")) return [{ number: 42, title: "Merged", user: null, head: { ref: "branch" }, base: { ref: "main" }, draft: false, state: "closed", merged_at: "2026-09-06", updated_at: "2026-09-06", html_url: "https://github.com/o/r/pull/42" }];
    throw new Error(`Unexpected request: ${path}`);
  });
  try {
    const report = await gh.checks(1, "o/r", "branch");
    expect(report.pushed).toBe(false);
    expect(report.pull?.state).toBe("merged");
    expect(report.pull?.number).toBe(42);
    expect(paths.some(path => path.includes("check-runs"))).toBe(false);
  } finally { request.mockRestore(); token.mockRestore(); }
});
