import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Db } from "./db";
import { confine, summarizeDiff } from "./tracks";

const ROOT = "/home/sprite/work/kyoto";

test("the file panel cannot read outside its own track", () => {
  // `GET /api/sandboxes/:id/file` will serve anything on the box, including
  // another track's work and `/home/sprite/.ssh`. This is what stops it.
  expect(confine(ROOT, null)).toBe(ROOT);
  expect(confine(ROOT, "src/app.ts")).toBe(`${ROOT}/src/app.ts`);
  expect(confine(ROOT, "../other/secret")).toBe(ROOT);
  expect(confine(ROOT, "/home/sprite/.ssh/id_ed25519")).toBe(ROOT);
  expect(confine(ROOT, "/home/sprite/work/kyoto-2/x")).toBe(ROOT);
  expect(confine(ROOT, `${ROOT}/deep/./file`)).toBe(`${ROOT}/deep/file`);
});

test("a diff is counted per file, without the headers", () => {
  const diff = [
    "diff --git a/src/app.ts b/src/app.ts",
    "index 111..222 100644",
    "--- a/src/app.ts",
    "+++ b/src/app.ts",
    "@@ -1,3 +1,4 @@",
    " context",
    "+added one",
    "+added two",
    "-removed one",
    "diff --git a/new.txt b/new.txt",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/new.txt",
    "@@ -0,0 +1,1 @@",
    "+hello",
  ].join("\n");

  expect(summarizeDiff(diff)).toEqual([
    // `+++` and `---` are file headers rather than content; counting them puts
    // a phantom line on every changed file.
    { path: "src/app.ts", added: 2, removed: 1, status: "modified" },
    { path: "new.txt", added: 1, removed: 0, status: "added" },
  ]);
});

test("a deletion and a rename are told apart", () => {
  const deleted = ["diff --git a/gone.ts b/gone.ts", "deleted file mode 100644", "--- a/gone.ts", "+++ /dev/null", "-x"].join("\n");
  expect(summarizeDiff(deleted)[0]).toEqual({ path: "gone.ts", added: 0, removed: 1, status: "deleted" });

  const renamed = ["diff --git a/old.ts b/new.ts", "similarity index 100%", "rename from old.ts", "rename to new.ts"].join("\n");
  expect(summarizeDiff(renamed)[0]?.status).toBe("renamed");
  expect(summarizeDiff(renamed)[0]?.path).toBe("new.ts");
});

test("an empty diff is an empty list, not a phantom file", () => {
  expect(summarizeDiff("")).toEqual([]);
  expect(summarizeDiff("\n\n")).toEqual([]);
});

// ── renaming ───────────────────────────────────────────────────────────

test("renaming a track moves the label and nothing on the machine", () => {
  const db = new Db(join(mkdtempSync(join(tmpdir(), "switchyard-tracks-")), "t.sqlite"));
  const user = db.upsertUser({ githubId: "1", login: "ana", name: "Ana", avatarUrl: null, tokenEnc: "x" });
  const project = db.createProject({
    id: "p1", userId: user.id, name: "ledger", repoFullName: "ana/ledger", repoPrivate: 1,
    defaultBranch: "main", installationId: 1, agentId: "a1", environmentId: "e1", vaultId: "v1",
    runtime: "claude", model: "anthropic/claude-opus-5", instructions: "",
  });
  db.createTrack({
    id: "t1", projectId: project.id, conversationId: "c1", slug: "kyoto", title: "Kyoto",
    branch: "ana/kyoto", workdir: ROOT, originKind: "blank", originBase: "main",
    originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "ana",
  });

  db.renameTrack("t1", "Rewrite the importer");

  const after = db.track("t1")!;
  expect(after.title).toBe("Rewrite the importer");
  // The three that were cut on a real machine when the track opened. A rename
  // that moved any of them would be moving a directory somebody is in — and
  // the slug is still spent for the next track either way.
  expect(after.slug).toBe("kyoto");
  expect(after.branch).toBe("ana/kyoto");
  expect(after.workdir).toBe(ROOT);
  expect(db.slugTaken(project.id, "kyoto")).toBe(true);
});
