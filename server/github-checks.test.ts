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

for (const scenario of [
  { name: "a reused name does not inherit an older PR", originNumber: null, created: "2026-09-01T00:00:00Z", expected: null },
  { name: "a PR made during this track is included", originNumber: null, created: "2026-09-06T12:00:01Z", expected: 27 },
  { name: "same-second creation tolerates GitHub timestamp precision", originNumber: null, created: "2026-09-06T12:00:00Z", expected: 27 },
  { name: "an explicit PR origin can predate its track", originNumber: 27, created: "2026-09-01T00:00:00Z", expected: 27 },
  { name: "an explicit PR origin does not select a different PR", originNumber: 28, created: "2026-09-01T00:00:00Z", expected: null },
]) {
  test(scenario.name, async () => {
    const gh = new GitHub({ appId: "1", slug: "test", clientId: "test", clientSecret: "test", privateKeyPem: "", webhookSecret: null, apiUrl: "https://api.github.com", webUrl: "https://github.com" });
    const token = spyOn(gh, "installationToken").mockResolvedValue("test");
    const transport = gh as unknown as { request(method: string, path: string): Promise<unknown> };
    const request = spyOn(transport, "request").mockImplementation(async (_, path) => {
      if (path.includes("/branches/")) throw new GitHubError(404, "Not Found");
      if (path.includes("/pulls?")) return [{ number: 27, title: "Old Antwerp", user: null, head: { ref: "jhgaylor/antwerp" }, base: { ref: "main" }, state: "closed", merged_at: "2026-09-06", created_at: scenario.created, updated_at: "2026-09-07T00:00:00Z" }];
      throw new Error(`Unexpected request: ${path}`);
    });
    try {
      const report = await gh.checks(1, "managoat/demos", "jhgaylor/antwerp", { createdAt: "2026-09-06T12:00:00.123Z", originNumber: scenario.originNumber });
      expect(report.pull?.number ?? null).toBe(scenario.expected);
    } finally { request.mockRestore(); token.mockRestore(); }
  });
}
