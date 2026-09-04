import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Db } from "./db";

/**
 * The membership boundary, written down.
 *
 * Sharing is per *track*, and the only thing standing between "help me on this
 * branch" and "here is my machine" is that the lookup is per row. These are
 * the ways in that stay shut.
 */

function fresh(): Db {
  return new Db(join(mkdtempSync(join(tmpdir(), "switchyard-people-")), "t.sqlite"));
}

function seed(db: Db) {
  const owner = db.upsertUser({ githubId: "1", login: "ana", name: "Ana", avatarUrl: null, tokenEnc: "x" });
  const guest = db.upsertUser({ githubId: "2", login: "bo", name: "Bo", avatarUrl: null, tokenEnc: "x" });
  const other = db.upsertUser({ githubId: "3", login: "cy", name: "Cy", avatarUrl: null, tokenEnc: "x" });
  const project = db.createProject({
    id: "p1",
    userId: owner.id,
    name: "ledger",
    repoFullName: "ana/ledger",
    repoPrivate: 1,
    defaultBranch: "main",
    installationId: 1,
    agentId: "a1",
    environmentId: "e1",
    vaultId: "v1",
    runtime: "claude",
    model: "anthropic/claude-opus-5",
    instructions: "",
  });
  const shared = db.createTrack({
    id: "t1", projectId: project.id, conversationId: "c1", slug: "crewe", title: "Crewe",
    branch: "ana/crewe", workdir: "/home/sprite/work/crewe", originKind: "blank",
    originBase: "main", originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "ana",
  });
  const private_ = db.createTrack({
    id: "t2", projectId: project.id, conversationId: "c2", slug: "selkirk", title: "Selkirk",
    branch: "ana/selkirk", workdir: "/home/sprite/work/selkirk", originKind: "blank",
    originBase: "main", originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "ana",
  });
  return { owner, guest, other, project, shared, private_ };
}

test("an invitation reaches one track and stops there", () => {
  const db = fresh();
  const { guest, shared, private_ } = seed(db);
  db.addMember(shared.id, guest.id, "owner");

  expect(db.isMember(shared.id, guest.id)).toBe(true);
  // The other track of the same project is not part of the deal, and this is
  // the assertion that keeps "an invitation is to a branch, not to a machine"
  // true rather than aspirational.
  expect(db.isMember(private_.id, guest.id)).toBe(false);
  expect(db.memberTracks(guest.id).map((t) => t.id)).toEqual([shared.id]);
});

test("somebody who was never invited is in nothing", () => {
  const db = fresh();
  const { other, shared } = seed(db);
  expect(db.isMember(shared.id, other.id)).toBe(false);
  expect(db.memberTracks(other.id)).toEqual([]);
});

test("removing somebody removes them, and only them", () => {
  const db = fresh();
  const { guest, other, shared } = seed(db);
  db.addMember(shared.id, guest.id, "owner");
  db.addMember(shared.id, other.id, "owner");
  db.removeMember(shared.id, guest.id);

  expect(db.isMember(shared.id, guest.id)).toBe(false);
  expect(db.isMember(shared.id, other.id)).toBe(true);
});

test("inviting twice is not two seats", () => {
  const db = fresh();
  const { guest, shared } = seed(db);
  db.addMember(shared.id, guest.id, "owner");
  db.addMember(shared.id, guest.id, "owner");
  expect(db.membersOf(shared.id)).toHaveLength(1);
});

test("closing a track takes its membership out of circulation", () => {
  const db = fresh();
  const { guest, shared } = seed(db);
  db.addMember(shared.id, guest.id, "owner");
  db.closeTrack(shared.id);
  // The row survives — history, and re-opening is not a thing — but the track
  // stops appearing as somewhere they can go.
  expect(db.memberTracks(guest.id)).toEqual([]);
});

test("the invite box finds people by login and by name, prefix first", () => {
  const db = fresh();
  const { owner } = seed(db);
  db.upsertUser({ githubId: "4", login: "joana", name: null, avatarUrl: null, tokenEnc: "x" });

  const hits = db.searchUsers("ana", owner.id).map((u) => u.login);
  // `ana` is the owner and excluded as the caller; `joana` contains it.
  expect(hits).toContain("joana");

  const byName = db.searchUsers("Bo", owner.id).map((u) => u.login);
  expect(byName).toContain("bo");
});

test("the invite box never suggests the person typing", () => {
  const db = fresh();
  const { owner } = seed(db);
  expect(db.searchUsers("ana", owner.id).map((u) => u.id)).not.toContain(owner.id);
});

// ── invitations to somebody who is not here yet ────────────────────────

test("an invitation waits on the GitHub account, not on a row we hold", async () => {
  const db = fresh();
  const { shared } = seed(db);
  db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  expect(db.invitesOf(shared.id).map((i) => i.login)).toEqual(["dana"]);
  // Nobody has joined: an invitation is a promise, not access.
  expect(db.membersOf(shared.id)).toHaveLength(0);

  const dana = db.upsertUser({ githubId: "9001", login: "dana", name: null, avatarUrl: null, tokenEnc: "x" });
  const joined = db.claimInvites(dana.id, "9001");

  expect(joined.map((t) => t.id)).toEqual([shared.id]);
  expect(db.isMember(shared.id, dana.id)).toBe(true);
  expect(db.invitesOf(shared.id)).toEqual([]);
});

test("a renamed login still finds them; a recycled one does not", async () => {
  const db = fresh();
  const { shared } = seed(db);
  db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  // They changed their name between the invitation and the sign-in.
  const renamed = db.upsertUser({ githubId: "9001", login: "dana-codes", name: null, avatarUrl: null, tokenEnc: "x" });
  expect(db.claimInvites(renamed.id, "9001")).toHaveLength(1);

  // And somebody else who later takes the *old* name gets nothing. This is
  // the whole reason the invitation is keyed on the numeric id.
  db.addInvite({ trackId: shared.id, githubId: "9002", login: "eli", avatarUrl: null, invitedBy: "owner" });
  const impostor = db.upsertUser({ githubId: "9999", login: "eli", name: null, avatarUrl: null, tokenEnc: "x" });
  expect(db.claimInvites(impostor.id, "9999")).toEqual([]);
  expect(db.isMember(shared.id, impostor.id)).toBe(false);
});

test("an invitation to a track that closed meanwhile grants nothing", () => {
  const db = fresh();
  const { shared } = seed(db);
  db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });
  db.closeTrack(shared.id);

  const dana = db.upsertUser({ githubId: "9001", login: "dana", name: null, avatarUrl: null, tokenEnc: "x" });
  expect(db.claimInvites(dana.id, "9001")).toEqual([]);
  expect(db.isMember(shared.id, dana.id)).toBe(false);
  // And it does not linger to be claimed by a later sign-in either.
  expect(db.invitesOf(shared.id)).toEqual([]);
});

test("an invitation can be withdrawn before it is taken up", () => {
  const db = fresh();
  const { shared } = seed(db);
  db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  expect(db.removeInviteByLogin(shared.id, "DANA")).toBe(true);
  expect(db.invitesOf(shared.id)).toEqual([]);
  expect(db.removeInviteByLogin(shared.id, "dana")).toBe(false);
});

// ── the link ───────────────────────────────────────────────────────────

test("minting a link revokes the one that was out", () => {
  const db = fresh();
  const { shared } = seed(db);
  db.putLink(shared.id, "hash-one", "owner", 60_000);
  db.putLink(shared.id, "hash-two", "owner", 60_000);

  // One row per track, so there is no "old link" left to work.
  expect(db.trackForLink("hash-one")).toBeNull();
  expect(db.trackForLink("hash-two")?.id).toBe(shared.id);
});

test("a link stops working when revoked, expired, or its track closes", () => {
  const db = fresh();
  const { shared, private_ } = seed(db);

  db.putLink(shared.id, "live", "owner", 60_000);
  expect(db.trackForLink("live")?.id).toBe(shared.id);
  db.dropLink(shared.id);
  expect(db.trackForLink("live")).toBeNull();

  db.putLink(shared.id, "stale", "owner", -1);
  expect(db.trackForLink("stale")).toBeNull();

  db.putLink(private_.id, "doomed", "owner", 60_000);
  db.closeTrack(private_.id);
  expect(db.trackForLink("doomed")).toBeNull();
});

test("an unknown token opens nothing", () => {
  const db = fresh();
  seed(db);
  expect(db.trackForLink("never-minted")).toBeNull();
});

test("a login lookup is case-insensitive, the way GitHub treats them", () => {
  const db = fresh();
  seed(db);
  expect(db.userByLogin("BO")?.login).toBe("bo");
  expect(db.userByLogin("nobody")).toBeNull();
});
