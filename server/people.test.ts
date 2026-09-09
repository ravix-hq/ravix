import { expect, test } from "bun:test";
import { Db } from "./db";
import { testSql } from "./sql";

/**
 * The membership boundaries, written down.
 *
 * There are two, and the tests come in two halves for that reason. A track
 * invitation is "help me on this branch" and stops at that row; a project
 * invitation is "work on this machine with me" and reaches every row on it.
 * What neither reaches is the machine's controls, which is `projectOf`'s job
 * and not a question the database can answer.
 *
 * The half worth reading twice is the interaction: the two grants are separate
 * rows, and the assertions below pin down what happens when one person has
 * both.
 */

async function fresh(): Promise<Db> {
  return Db.open(await testSql());
}

async function seed(db: Db) {
  const owner = await db.upsertUser({ githubId: "1", login: "ana", name: "Ana", avatarUrl: null, tokenEnc: "x" });
  const guest = await db.upsertUser({ githubId: "2", login: "bo", name: "Bo", avatarUrl: null, tokenEnc: "x" });
  const other = await db.upsertUser({ githubId: "3", login: "cy", name: "Cy", avatarUrl: null, tokenEnc: "x" });
  const project = await db.createProject({
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
  const shared = await db.createTrack({
    id: "t1", projectId: project.id, conversationId: "c1", slug: "crewe", title: "Crewe",
    branch: "ana/crewe", workdir: "/home/sprite/work/crewe", originKind: "blank",
    originBase: "main", originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "ana",
  });
  const private_ = await db.createTrack({
    id: "t2", projectId: project.id, conversationId: "c2", slug: "selkirk", title: "Selkirk",
    branch: "ana/selkirk", workdir: "/home/sprite/work/selkirk", originKind: "blank",
    originBase: "main", originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "ana",
  });
  return { owner, guest, other, project, shared, private_ };
}

test("an invitation reaches one track and stops there", async () => {
  const db = await fresh();
  const { guest, shared, private_ } = await seed(db);
  await db.addMember(shared.id, guest.id, "owner");

  expect(await db.isMember(shared.id, guest.id)).toBe(true);
  // The other track of the same project is not part of the deal, and this is
  // the assertion that keeps "an invitation is to a branch, not to a machine"
  // true rather than aspirational.
  expect(await db.isMember(private_.id, guest.id)).toBe(false);
  expect((await db.memberTracks(guest.id)).map((t) => t.id)).toEqual([shared.id]);
});

test("somebody who was never invited is in nothing", async () => {
  const db = await fresh();
  const { other, shared } = await seed(db);
  expect(await db.isMember(shared.id, other.id)).toBe(false);
  expect(await db.memberTracks(other.id)).toEqual([]);
});

test("removing somebody removes them, and only them", async () => {
  const db = await fresh();
  const { guest, other, shared } = await seed(db);
  await db.addMember(shared.id, guest.id, "owner");
  await db.addMember(shared.id, other.id, "owner");
  await db.removeMember(shared.id, guest.id);

  expect(await db.isMember(shared.id, guest.id)).toBe(false);
  expect(await db.isMember(shared.id, other.id)).toBe(true);
});

test("inviting twice is not two seats", async () => {
  const db = await fresh();
  const { guest, shared } = await seed(db);
  await db.addMember(shared.id, guest.id, "owner");
  await db.addMember(shared.id, guest.id, "owner");
  expect(await db.membersOf(shared.id)).toHaveLength(1);
});

test("closing a track takes its membership out of circulation", async () => {
  const db = await fresh();
  const { guest, shared } = await seed(db);
  await db.addMember(shared.id, guest.id, "owner");
  await db.closeTrack(shared.id);
  // The row survives — history, and re-opening is not a thing — but the track
  // stops appearing as somewhere they can go.
  expect(await db.memberTracks(guest.id)).toEqual([]);
});

test("the invite box finds people by login and by name, prefix first", async () => {
  const db = await fresh();
  const { owner } = await seed(db);
  await db.upsertUser({ githubId: "4", login: "joana", name: null, avatarUrl: null, tokenEnc: "x" });

  const hits = (await db.searchUsers("ana", owner.id)).map((u) => u.login);
  // `ana` is the owner and excluded as the caller; `joana` contains it.
  expect(hits).toContain("joana");

  const byName = (await db.searchUsers("Bo", owner.id)).map((u) => u.login);
  expect(byName).toContain("bo");
});

test("the invite box never suggests the person typing", async () => {
  const db = await fresh();
  const { owner } = await seed(db);
  expect((await db.searchUsers("ana", owner.id)).map((u) => u.id)).not.toContain(owner.id);
});

// ── invitations to somebody who is not here yet ────────────────────────

test("an invitation waits on the GitHub account, not on a row we hold", async () => {
  const db = await fresh();
  const { shared } = await seed(db);
  await db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  expect((await db.invitesOf(shared.id)).map((i) => i.login)).toEqual(["dana"]);
  // Nobody has joined: an invitation is a promise, not access.
  expect(await db.membersOf(shared.id)).toHaveLength(0);

  const dana = await db.upsertUser({ githubId: "9001", login: "dana", name: null, avatarUrl: null, tokenEnc: "x" });
  const joined = await db.claimInvites(dana.id, "9001");

  expect(joined.tracks.map((t) => t.id)).toEqual([shared.id]);
  expect(await db.isMember(shared.id, dana.id)).toBe(true);
  expect(await db.invitesOf(shared.id)).toEqual([]);
});

test("a renamed login still finds them; a recycled one does not", async () => {
  const db = await fresh();
  const { shared } = await seed(db);
  await db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  // They changed their name between the invitation and the sign-in.
  const renamed = await db.upsertUser({ githubId: "9001", login: "dana-codes", name: null, avatarUrl: null, tokenEnc: "x" });
  expect((await db.claimInvites(renamed.id, "9001")).tracks).toHaveLength(1);

  // And somebody else who later takes the *old* name gets nothing. This is
  // the whole reason the invitation is keyed on the numeric id.
  await db.addInvite({ trackId: shared.id, githubId: "9002", login: "eli", avatarUrl: null, invitedBy: "owner" });
  const impostor = await db.upsertUser({ githubId: "9999", login: "eli", name: null, avatarUrl: null, tokenEnc: "x" });
  expect((await db.claimInvites(impostor.id, "9999")).tracks).toEqual([]);
  expect(await db.isMember(shared.id, impostor.id)).toBe(false);
});

test("an invitation to a track that closed meanwhile grants nothing", async () => {
  const db = await fresh();
  const { shared } = await seed(db);
  await db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });
  await db.closeTrack(shared.id);

  const dana = await db.upsertUser({ githubId: "9001", login: "dana", name: null, avatarUrl: null, tokenEnc: "x" });
  expect((await db.claimInvites(dana.id, "9001")).tracks).toEqual([]);
  expect(await db.isMember(shared.id, dana.id)).toBe(false);
  // And it does not linger to be claimed by a later sign-in either.
  expect(await db.invitesOf(shared.id)).toEqual([]);
});

test("an invitation can be withdrawn before it is taken up", async () => {
  const db = await fresh();
  const { shared } = await seed(db);
  await db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  expect(await db.removeInviteByLogin(shared.id, "DANA")).toBe(true);
  expect(await db.invitesOf(shared.id)).toEqual([]);
  expect(await db.removeInviteByLogin(shared.id, "dana")).toBe(false);
});

// ── the link ───────────────────────────────────────────────────────────

test("minting a link revokes the one that was out", async () => {
  const db = await fresh();
  const { shared } = await seed(db);
  await db.putLink(shared.id, "hash-one", "owner", 60_000);
  await db.putLink(shared.id, "hash-two", "owner", 60_000);

  // One row per track, so there is no "old link" left to work.
  expect(await db.trackForLink("hash-one")).toBeNull();
  expect((await db.trackForLink("hash-two"))?.id).toBe(shared.id);
});

test("a link stops working when revoked, expired, or its track closes", async () => {
  const db = await fresh();
  const { shared, private_ } = await seed(db);

  await db.putLink(shared.id, "live", "owner", 60_000);
  expect((await db.trackForLink("live"))?.id).toBe(shared.id);
  await db.dropLink(shared.id);
  expect(await db.trackForLink("live")).toBeNull();

  await db.putLink(shared.id, "stale", "owner", -1);
  expect(await db.trackForLink("stale")).toBeNull();

  await db.putLink(private_.id, "doomed", "owner", 60_000);
  await db.closeTrack(private_.id);
  expect(await db.trackForLink("doomed")).toBeNull();
});

test("an unknown token opens nothing", async () => {
  const db = await fresh();
  await seed(db);
  expect(await db.trackForLink("never-minted")).toBeNull();
});

test("a login lookup is case-insensitive, the way GitHub treats them", async () => {
  const db = await fresh();
  await seed(db);
  expect((await db.userByLogin("BO"))?.login).toBe("bo");
  expect(await db.userByLogin("nobody")).toBeNull();
});

// ── the wider grain: the whole project ─────────────────────────────────

test("a project membership reaches every track on it, including later ones", async () => {
  const db = await fresh();
  const { guest, project, shared, private_ } = await seed(db);
  await db.addProjectMember(project.id, guest.id, "owner");

  expect(await db.isProjectMember(project.id, guest.id)).toBe(true);
  // Both of the tracks that existed when they were let in…
  expect((await db.tracksOf(project.id)).map((t) => t.id).sort()).toEqual([shared.id, private_.id].sort());
  // …and the one cut afterwards, which is the difference between this and
  // sending two track invitations. Nothing has to be written when it opens.
  const later = await db.createTrack({
    id: "t3", projectId: project.id, conversationId: "c3", slug: "dover", title: "Dover",
    branch: "ana/dover", workdir: "/home/sprite/work/dover", originKind: "blank",
    originBase: "main", originNumber: null, originTitle: null, originUrl: null, rev: 1, createdByLogin: "ana",
  });
  expect(await db.isProjectMember(later.projectId, guest.id)).toBe(true);
});

test("a project membership is not a track membership", async () => {
  const db = await fresh();
  const { guest, project, shared } = await seed(db);
  await db.addProjectMember(project.id, guest.id, "owner");

  // The two tables are what the rail reads to decide which controls to draw,
  // so a project member must not turn up as a track member of anything: they
  // reach it through `trackAccess`'s second question instead.
  expect(await db.isMember(shared.id, guest.id)).toBe(false);
  expect(await db.memberTracks(guest.id)).toEqual([]);
  expect((await db.memberProjects(guest.id)).map((p) => p.id)).toEqual([project.id]);
});

test("the wider grant replaces the narrower ones, so nobody holds two", async () => {
  const db = await fresh();
  const { guest, project, shared } = await seed(db);
  await db.addMember(shared.id, guest.id, "owner");
  await db.addProjectMember(project.id, guest.id, "owner");

  // One person, one grade of access to a project. Two rows granting the same
  // person the same track by different routes is a state no list can render
  // honestly, and a revoke that left one behind would leave access nothing
  // explained.
  expect(await db.isProjectMember(project.id, guest.id)).toBe(true);
  expect(await db.isMember(shared.id, guest.id)).toBe(false);

  // So removing them from the project is the whole revoke, which is the
  // surprising half and the reason the dialog says it out loud.
  await db.removeProjectMember(project.id, guest.id);
  expect(await db.memberProjects(guest.id)).toEqual([]);
  expect(await db.memberTracks(guest.id)).toEqual([]);
});

test("the owner is never a member of their own project", async () => {
  const db = await fresh();
  const { owner, project } = await seed(db);
  await db.addProjectInvite({ projectId: project.id, githubId: "1", login: "ana", avatarUrl: null, invitedBy: "somebody" });

  // Ownership is the stronger claim and it is a column on the project rather
  // than a row here — so claiming an invitation to your own project writes
  // nothing, and cannot end with the owner able to lose themselves by leaving.
  expect((await db.claimInvites(owner.id, "1")).projects).toEqual([]);
  expect(await db.isProjectMember(project.id, owner.id)).toBe(false);
  expect(await db.projectMembersOf(project.id)).toEqual([]);
});

test("a project invitation waits on the GitHub account, like a track's", async () => {
  const db = await fresh();
  const { project } = await seed(db);
  await db.addProjectInvite({ projectId: project.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  expect((await db.projectInvitesOf(project.id)).map((i) => i.login)).toEqual(["dana"]);
  expect(await db.projectMembersOf(project.id)).toEqual([]);

  const dana = await db.upsertUser({ githubId: "9001", login: "dana", name: null, avatarUrl: null, tokenEnc: "x" });
  const joined = await db.claimInvites(dana.id, "9001");

  expect(joined.projects.map((p) => p.id)).toEqual([project.id]);
  expect(await db.isProjectMember(project.id, dana.id)).toBe(true);
  expect(await db.projectInvitesOf(project.id)).toEqual([]);
});

test("a sign-in holding both invitations ends up in the project, once", async () => {
  const db = await fresh();
  const { project, shared } = await seed(db);
  await db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });
  await db.addProjectInvite({ projectId: project.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  const dana = await db.upsertUser({ githubId: "9001", login: "dana", name: null, avatarUrl: null, tokenEnc: "x" });
  const joined = await db.claimInvites(dana.id, "9001");

  // Projects are claimed first, so the track invitation grants nothing they do
  // not already have and is dropped rather than written — otherwise the order
  // of two rows would decide whether somebody ends up at one grade or two.
  expect(joined.projects).toHaveLength(1);
  expect(joined.tracks).toEqual([]);
  expect(await db.isProjectMember(project.id, dana.id)).toBe(true);
  expect(await db.isMember(shared.id, dana.id)).toBe(false);
  // And neither invitation is left behind to be claimed a second time.
  expect(await db.invitesOf(shared.id)).toEqual([]);
  expect(await db.projectInvitesOf(project.id)).toEqual([]);
});

test("a project invitation supersedes a pending track one on the same project", async () => {
  const db = await fresh();
  const { project, shared, private_ } = await seed(db);
  await db.addInvite({ trackId: shared.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });
  await db.addProjectInvite({ projectId: project.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  // Otherwise the track's people list keeps a pending row whose × cancels an
  // invitation that was already superseded — a control that reads as taking
  // access away and does not.
  expect(await db.invitesOf(shared.id)).toEqual([]);
  expect((await db.projectInvitesOf(project.id)).map((i) => i.login)).toEqual(["dana"]);
  expect(await db.hasProjectInvite(project.id, "9001")).toBe(true);

  // Only on that project, though: an invitation to a track of somebody else's
  // machine is a different decision entirely.
  expect(await db.hasProjectInvite("nope", "9001")).toBe(false);
  expect(await db.invitesOf(private_.id)).toEqual([]);
});

test("a project invitation can be withdrawn before it is taken up", async () => {
  const db = await fresh();
  const { project } = await seed(db);
  await db.addProjectInvite({ projectId: project.id, githubId: "9001", login: "dana", avatarUrl: null, invitedBy: "owner" });

  expect(await db.removeProjectInviteByLogin(project.id, "DANA")).toBe(true);
  expect(await db.projectInvitesOf(project.id)).toEqual([]);
  expect(await db.removeProjectInviteByLogin(project.id, "dana")).toBe(false);
});

test("a project link behaves like a track's, and the two do not collide", async () => {
  const db = await fresh();
  const { project, shared } = await seed(db);

  await db.putProjectLink(project.id, "p-one", "owner", 60_000);
  await db.putProjectLink(project.id, "p-two", "owner", 60_000);
  // One row per project, so minting is the revoke here too.
  expect(await db.projectForLink("p-one")).toBeNull();
  expect((await db.projectForLink("p-two"))?.id).toBe(project.id);

  await db.dropProjectLink(project.id);
  expect(await db.projectForLink("p-two")).toBeNull();

  await db.putProjectLink(project.id, "stale", "owner", -1);
  expect(await db.projectForLink("stale")).toBeNull();

  // `/j/:token` tries both tables, so a token that opens one must not open the
  // other — otherwise a track link would quietly hand over the whole machine.
  await db.putLink(shared.id, "t-token", "owner", 60_000);
  await db.putProjectLink(project.id, "p-token", "owner", 60_000);
  expect(await db.projectForLink("t-token")).toBeNull();
  expect(await db.trackForLink("p-token")).toBeNull();
});

test("an archived project's link opens nothing, and its people go with it", async () => {
  const db = await fresh();
  const { guest, project } = await seed(db);
  await db.addProjectMember(project.id, guest.id, "owner");
  await db.putProjectLink(project.id, "live", "owner", 60_000);

  await db.archiveProject(project.id);

  expect(await db.projectForLink("live")).toBeNull();
  // The row survives — this is an archive, not a delete — but the project
  // stops appearing as somewhere they can go, exactly as a closed track does.
  expect(await db.memberProjects(guest.id)).toEqual([]);
});
