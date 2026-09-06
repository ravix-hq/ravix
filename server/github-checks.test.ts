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

function client() {
  return new GitHub({ appId: "1", slug: "test", clientId: "test", clientSecret: "test", privateKeyPem: "", webhookSecret: null, apiUrl: "https://api.github.com", webUrl: "https://github.com" });
}

test("viewers share in-flight checks and cached reports, then refresh after five minutes", async () => {
  const gh = client();
  const token = spyOn(gh, "installationToken").mockResolvedValue("test");
  let now = 1_000_000;
  const clock = spyOn(Date, "now").mockImplementation(() => now);
  const fetcher = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async (input: Parameters<typeof fetch>[0]) => {
    const url = String(input);
    return Response.json(url.includes("/branches/") ? { commit: { sha: "abc" } } : url.includes("check-runs") ? { check_runs: [] } : []);
  }, { preconnect: fetch.preconnect }));
  try {
    await Promise.all(Array.from({ length: 20 }, () => gh.checks(1, "o/r", "branch")));
    expect(fetcher).toHaveBeenCalledTimes(3);
    await gh.checks(1, "o/r", "branch");
    expect(fetcher).toHaveBeenCalledTimes(3);
    now += 300_001;
    await gh.checks(1, "o/r", "branch");
    expect(fetcher).toHaveBeenCalledTimes(6);
    await gh.checks(2, "o/r", "branch");
    expect(fetcher).toHaveBeenCalledTimes(9);
  } finally { fetcher.mockRestore(); token.mockRestore(); clock.mockRestore(); }
});

for (const headers of [
  { "x-ratelimit-remaining": "0", "x-ratelimit-reset": "1600" },
  { "retry-after": "600" },
] as Record<string, string>[]) {
  test(`rate limits stop all reads for an installation until reset: ${JSON.stringify(headers)}`, async () => {
    const gh = client();
    const token = spyOn(gh, "installationToken").mockResolvedValue("test");
    let now = 1_000_000;
    const clock = spyOn(Date, "now").mockImplementation(() => now);
    const fetcher = spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(Response.json({ message: "API rate limit exceeded" }, { status: 403, headers }))
      .mockImplementation(Object.assign(async () => Response.json([]), { preconnect: fetch.preconnect }));
    try {
      await expect(gh.checks(1, "o/r", "a")).rejects.toThrow("rate limit");
      await expect(gh.checks(1, "o/r", "a")).rejects.toThrow("rate limit");
      await expect(gh.checks(1, "o/r", "b")).rejects.toThrow("rate limit");
      await expect(gh.pulls(1, "o/other")).rejects.toThrow("rate limit");
      expect(fetcher).toHaveBeenCalledTimes(1);
      await gh.pulls(2, "o/r");
      expect(fetcher).toHaveBeenCalledTimes(2);
      now = 1_600_001;
      await gh.pulls(1, "o/r");
      expect(fetcher).toHaveBeenCalledTimes(3);
    } finally { fetcher.mockRestore(); token.mockRestore(); clock.mockRestore(); }
  });
}

test("permission failures do not block unrelated installation reads", async () => {
  const gh = client();
  const token = spyOn(gh, "installationToken").mockResolvedValue("test");
  const fetcher = spyOn(globalThis, "fetch")
    .mockResolvedValueOnce(Response.json({ message: "Forbidden" }, { status: 403 }))
    .mockResolvedValueOnce(Response.json([]));
  try {
    await expect(gh.checks(1, "o/r", "a")).rejects.toThrow("Forbidden");
    await gh.pulls(1, "o/r");
    expect(fetcher).toHaveBeenCalledTimes(2);
  } finally { fetcher.mockRestore(); token.mockRestore(); }
});
