/**
 * Working on something with somebody else.
 *
 * There are **two units of sharing**, and offering both is the design rather
 * than a convenience. A track is one branch in one directory; a project is the
 * machine every track sits on. Inviting somebody to a branch is a thing people
 * do every day, and for a long time it was the only thing switchyard offered —
 * on the argument that inviting somebody to your *machine* is not an everyday
 * act, which is true. What that argument missed is that working with the same
 * person across a week of branches, re-inviting them to each one, is not an
 * everyday act either. So:
 *
 *   **A track member** gets exactly the track they were named on: its
 *   transcript, files, diff, terminal, and the ability to prompt it. They do
 *   not see the project's other tracks and cannot open one.
 *
 *   **A project member** gets every track on that project — the ones open now
 *   and the ones opened tomorrow — and may cut tracks of their own. A project
 *   you were let into where you cannot start a line of work is only a bundle
 *   of track invitations under a grander name.
 *
 * Neither of them gets the project's **controls**: settings, packages,
 * secrets, rebuild, delete. That line is the one thing both memberships have
 * in common and it is drawn in `context.ts` — `projectOf` for the machine,
 * `projectAccess` for the work on it, `trackAccess` for one piece of the work.
 *
 * **One person holds one grade of access to a project.** Inviting somebody to
 * the whole project deletes any track rows they held on it, and inviting a
 * project member to a single track is refused as the no-op it is. The
 * corollary is the surprising half and is said in the dialog: removing
 * somebody from a project takes away every track on it, including one they
 * were named on separately beforehand. The alternative is a narrower row that
 * survives invisibly — worse, because it is invisible at exactly the moment
 * somebody is trying to revoke access. `Db.addProjectMember` is where that is
 * enforced, so the three ways in cannot disagree about it.
 *
 * ## What sharing actually costs
 *
 * It is worth being exact, because the invite dialogs say it and this is where
 * the sentence is true or not.
 *
 * A track is a shell on a machine that also holds every *other* track. The
 * worktrees are separate directories, and the agent is told three times over
 * to stay in its own — but that is a rule the agent follows, not a boundary
 * the kernel enforces. Somebody who can prompt a track can ask the agent to
 * read a sibling directory, and it may do it. They can also ask it to print
 * the environment, which on a project with environment secrets means those
 * secrets.
 *
 * Which is the honest reason project-level sharing is not the leap it looks
 * like: a track invitation *already* costs most of what a project invitation
 * costs, because they run on one box. What the wider one adds is the ability
 * to read the other transcripts and to open tracks — real, and worth a
 * separate act by the owner, but not a different order of trust.
 *
 * What neither can do is reach the project's controls. The one worth knowing
 * is the credential: the clone token lives in the vault and never lands on the
 * machine, so no member can print it — the machine does not have it to print.
 */
import type { Person } from "../shared/api";
import type { AppContext } from "./context";
import { authenticate, projectAccess, requireGitHub, requireOwner, trackAccess } from "./context";
import { asHttpError as asGitHubError } from "./github";
import type { UserRow } from "./db";
import { HttpError, SESSION_COOKIE, cookieValue, json, readJson, str } from "./http";
import { randomToken, sha256 } from "./crypto";
import { callbackUrl } from "./auth";
import { publish } from "./hub";

/**
 * `GET /api/users?q=` — the invite box's autocomplete.
 *
 * This searches **everyone who has ever signed in to this deployment**, and
 * that is a deliberate, accepted trade rather than an oversight: it means the
 * box will confirm whether a given GitHub login has an account here. The
 * alternative — only suggesting people you have already shared with — makes
 * the box useless for the first invitation anybody sends, which is the one
 * that matters.
 *
 * Two things keep it from being worse than that. It needs a session, so it is
 * not an open directory of the userbase; and it returns only what GitHub
 * already publishes about a person — login, display name, avatar — never an
 * email, and never anything about what they have here.
 */
export async function search(ctx: AppContext, req: Request): Promise<Response> {
  const user = await authenticate(ctx, req);
  const q = (new URL(req.url).searchParams.get("q") ?? "").trim();
  // One character is a fine query for a login; zero is a request for the
  // whole userbase, which is the one thing this should not hand over.
  if (q.length < 1) return json({ data: [] });
  return json({ data: ctx.db.searchUsers(q.slice(0, 60), user.id).map(toPerson) });
}

/** `GET /api/tracks/:id/people` — who can reach this track. */
export async function list(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackAccess(ctx, user, trackId);
  return json({ data: peopleOf(ctx, track.id, project.userId, project.id) });
}

/**
 * A typed username, resolved to whoever it names.
 *
 * Two answers, because switchyard has two kinds of invitation and the
 * difference is not a detail: somebody who has signed in here is a row we can
 * grant access to now, and somebody who has not is an account on GitHub that
 * an invitation has to *wait* for. Shared by both grains of invite so the
 * error sentences — and the GitHub lookup that produces the good ones — cannot
 * drift between the track dialog and the project dialog.
 */
async function resolveLogin(
  ctx: AppContext,
  raw: unknown,
): Promise<{ user: UserRow; githubId: string } | { user: null; githubId: string; login: string; avatarUrl: string | null }> {
  const login = str(raw, 80).trim().replace(/^@/, "");
  if (!login) throw new HttpError(422, "no_login", "Give a GitHub username.");

  // Somebody who has signed in here joins immediately.
  const existing = ctx.db.userByLogin(login);
  if (existing) return { user: existing, githubId: existing.githubId };

  // Anybody else is invited on GitHub's account rather than on ours. The
  // invitation waits for them to sign in, and is stored against the numeric
  // id rather than the name they had today.
  const gh = requireGitHub(ctx);
  let account;
  try {
    account = await gh.userByLogin(login);
  } catch (err) {
    throw asGitHubError(err, "look up that username");
  }
  if (!account) throw new HttpError(404, "no_such_user", `There is no GitHub user called @${login}.`);
  return { user: null, githubId: String(account.id), login: account.login, avatarUrl: account.avatar_url };
}

/**
 * `POST /api/tracks/:id/people` — invite somebody by GitHub login.
 *
 * They need not already have signed in here: a username with no account is
 * resolved against GitHub and the invitation waits on their account. What
 * switchyard cannot do is invite a *stranger* — sign-in is GitHub and this app
 * never asks for an email, so there is no address to send anything to, and a
 * row naming a login that has never appeared would be a permission granted to
 * whoever claimed that name first.
 */
export async function add(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project, role } = trackAccess(ctx, user, trackId);
  requireOwner(role, "invite people to a track");

  const body = await readJson(req);
  const found = await resolveLogin(ctx, body.login);
  if (found.githubId === ctx.db.user(project.userId)?.githubId) {
    throw new HttpError(422, "already_owner", "That is the owner of this project — they are already in every track of it.");
  }
  // Somebody already in the whole project — or on their way into it — reaches
  // this track by the wider row. Writing a narrower one on top would be a
  // no-op that the list cannot show and that `addProjectMember` would delete
  // on the next promotion anyway. Refused rather than silently ignored,
  // because the owner is entitled to know their click did nothing.
  const login = found.user ? found.user.login : found.login;
  if (found.user && ctx.db.isProjectMember(project.id, found.user.id)) {
    throw new HttpError(422, "already_in_project", `@${login} is in this whole project already, so they are already in this track.`);
  }
  if (ctx.db.hasProjectInvite(project.id, found.githubId)) {
    throw new HttpError(422, "already_in_project", `@${login} is already invited to this whole project, so they will reach this track too.`);
  }

  if (found.user) ctx.db.addMember(track.id, found.user.id, user.id);
  else ctx.db.addInvite({ trackId: track.id, githubId: found.githubId, login: found.login, avatarUrl: found.avatarUrl, invitedBy: user.id });

  publish(project.id, { event: "people", data: { trackId: track.id } });
  return json({ data: peopleOf(ctx, track.id, project.userId, project.id) }, 201);
}

/**
 * `DELETE /api/tracks/:id/people/:login` — the owner removing somebody, or
 * somebody removing themselves.
 *
 * Both are the same row and the same effect, so they are the same route. The
 * difference is only who may ask, and letting a member leave without going
 * through the owner is the difference between a shared track and a summons.
 */
export async function remove(ctx: AppContext, req: Request, trackId: string, login: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project, role } = trackAccess(ctx, user, trackId);

  const wanted = login.replace(/^@/, "");

  // An invitation that has not been taken up yet is cancelled rather than
  // removed — there is no membership to delete, only a promise to withdraw.
  // Owner-only, because a pending person has no session to ask with.
  if (role === "owner" && ctx.db.removeInviteByLogin(track.id, wanted)) {
    publish(project.id, { event: "people", data: { trackId: track.id } });
    return json({ data: peopleOf(ctx, track.id, project.userId, project.id) });
  }

  const target = ctx.db.userByLogin(wanted);
  if (!target) throw new HttpError(404, "not_found", "No such person on this track.");
  if (role !== "owner" && target.id !== user.id) {
    throw new HttpError(403, "owner_only", "Only the owner of this project can remove somebody else.");
  }
  // Somebody here by way of the *project* is not this dialog's to remove.
  // Silently widening one click into "out of every track on this machine"
  // would be the most surprising thing either dialog could do, so it is named
  // and refused, and the sentence says where the control actually is.
  if (ctx.db.isProjectMember(project.id, target.id)) {
    throw new HttpError(
      409,
      "in_whole_project",
      target.id === user.id
        ? "You are in this whole project, not just this track. Leave the project to give up its tracks."
        : `@${target.login} is in this whole project, not just this track. Remove them from the project's people to take this away.`,
    );
  }

  ctx.db.removeMember(track.id, target.id);
  publish(project.id, { event: "people", data: { trackId: track.id } });
  // The caller may have just removed their own access, in which case there is
  // nothing left to hand back — 204 rather than a list they cannot see.
  if (target.id === user.id && role !== "owner") return new Response(null, { status: 204 });
  return json({ data: peopleOf(ctx, track.id, project.userId, project.id) });
}

/**
 * Everyone on a track, owner first.
 *
 * The owner is not a row in `track_members` — they own the project, which is a
 * stronger claim that survives every membership being deleted — so they are
 * prepended here rather than written into the table. A synthetic row would
 * have to be kept in step with the project's `user_id` forever, and the day it
 * was not, the owner would lose their own track.
 *
 * Project members are in this list too, because the question it answers is
 * "who can see this" and they can. They carry `via: "project"` so the dialog
 * can say *why* — a name you do not remember inviting to this branch is
 * alarming until the row tells you it came in one level up — and so the ×
 * beside them can be the control that actually works.
 *
 * Somebody who is both is shown once, as a project member: that is the row
 * that is granting the access, and it is the one whose removal would not be
 * enough on its own.
 */
export function peopleOf(ctx: AppContext, trackId: string, ownerId: string, projectId: string): Person[] {
  const owner = ctx.db.user(ownerId);
  const wide = ctx.db.projectMembersOf(projectId);
  const seen = new Set(wide.map((u) => u.id));
  const narrow = ctx.db.membersOf(trackId).filter((u) => !seen.has(u.id));
  // Pending last, because they cannot read anything yet and the list is
  // mostly read to answer "who can see this".
  const pending = ctx.db.invitesOf(trackId).map((i) => ({ login: i.login, name: null, avatarUrl: i.avatarUrl, pending: true }));
  return [
    ...(owner ? [owner].map(toPerson) : []),
    ...wide.map((u) => ({ ...toPerson(u), via: "project" as const })),
    ...narrow.map((u) => ({ ...toPerson(u), via: "track" as const })),
    ...pending,
  ];
}

/**
 * Everyone on a project, owner first — the same list one level up.
 *
 * Deliberately *not* a union with the track memberships underneath it. This
 * list answers "who is in the project", and somebody named on one branch of it
 * is not; showing them here would make the owner's own decision unreadable
 * back to them, and would put a × beside a row that this dialog cannot remove.
 */
export function projectPeopleOf(ctx: AppContext, projectId: string, ownerId: string): Person[] {
  const owner = ctx.db.user(ownerId);
  const members = ctx.db.projectMembersOf(projectId);
  const pending = ctx.db.projectInvitesOf(projectId).map((i) => ({ login: i.login, name: null, avatarUrl: i.avatarUrl, pending: true }));
  return [...(owner ? [owner].map(toPerson) : []), ...members.map(toPerson), ...pending];
}

// ── the same three routes, one level up ────────────────────────────────

/** `GET /api/projects/:id/people` — who can reach every track on this project. */
export async function listProject(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { project } = projectAccess(ctx, user, projectId);
  return json({ data: projectPeopleOf(ctx, project.id, project.userId) });
}

/**
 * `POST /api/projects/:id/people` — invite somebody to the whole project.
 *
 * The same act as the track's, one level up, and the same two outcomes: a
 * membership for somebody who has signed in here, an invitation waiting on
 * GitHub for somebody who has not. What differs is what it grants, and that
 * difference is the dialog's to explain — see the header of this file.
 *
 * Owner-only, and there is no argument for widening it. A member who could
 * invite could hand out the machine they were lent, and the owner would find
 * out from the people list.
 */
export async function addProject(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { project, role } = projectAccess(ctx, user, projectId);
  requireOwner(role, "invite people to a project");

  const body = await readJson(req);
  const found = await resolveLogin(ctx, body.login);
  if (found.githubId === ctx.db.user(project.userId)?.githubId) {
    throw new HttpError(422, "already_owner", "That is the owner of this project.");
  }

  // `addProjectMember` is a promotion: any track rows they held on this
  // project go with it, so the list cannot end up showing one person at two
  // grades.
  if (found.user) {
    ctx.db.addProjectMember(project.id, found.user.id, user.id);
  } else {
    ctx.db.addProjectInvite({
      projectId: project.id,
      githubId: found.githubId,
      login: found.login,
      avatarUrl: found.avatarUrl,
      invitedBy: user.id,
    });
  }

  // No `trackId`: this changed who is on every track of the project at once,
  // and the browser re-reads the rail rather than one row.
  publish(project.id, { event: "people", data: {} });
  return json({ data: projectPeopleOf(ctx, project.id, project.userId) }, 201);
}

/**
 * `DELETE /api/projects/:id/people/:login` — the owner removing somebody, or
 * somebody leaving.
 *
 * This gives up **every track on the project**, in one go and including any
 * the person was named on individually before they were let into the whole
 * thing — those rows were deleted when they were promoted. It is a bigger door
 * than leaving one track, which is why the dialog asks twice and says so in
 * the sentence above the button.
 */
export async function removeProject(ctx: AppContext, req: Request, projectId: string, login: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { project, role } = projectAccess(ctx, user, projectId);

  const wanted = login.replace(/^@/, "");

  // As on a track: an invitation nobody has taken up is withdrawn rather than
  // removed. Owner-only, because a pending person has no session to ask with.
  if (role === "owner" && ctx.db.removeProjectInviteByLogin(project.id, wanted)) {
    publish(project.id, { event: "people", data: {} });
    return json({ data: projectPeopleOf(ctx, project.id, project.userId) });
  }

  const target = ctx.db.userByLogin(wanted);
  if (!target) throw new HttpError(404, "not_found", "No such person on this project.");
  if (role !== "owner" && target.id !== user.id) {
    throw new HttpError(403, "owner_only", "Only the owner of this project can remove somebody else.");
  }

  ctx.db.removeProjectMember(project.id, target.id);
  publish(project.id, { event: "people", data: {} });
  // Nothing left to hand back to somebody who just removed their own access:
  // 204 rather than a list they cannot see. The caller has to leave rather
  // than re-render.
  if (target.id === user.id && role !== "owner") return new Response(null, { status: 204 });
  return json({ data: projectPeopleOf(ctx, project.id, project.userId) });
}

// ── the other way in: a link ───────────────────────────────────────────

/**
 * How long a link lasts.
 *
 * A week for a track, because the thing it is for is "have a look at this with
 * me", not "here is standing access". A link that never expires is a
 * credential somebody pasted into a chat two years ago and forgot, and this
 * one grants a shell on a machine.
 *
 * Two days for a project, and the shorter number is the whole of the argument
 * for having two. A project link is the widest thing switchyard hands out —
 * every branch on the box, and the ability to cut more — so it is the one that
 * should least survive being forgotten about. Nobody is worse off: minting
 * another is one button, and the people who came in on the old one stay.
 */
const LINK_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const PROJECT_LINK_TTL_MS = 2 * 24 * 60 * 60 * 1000;

/** `GET /api/tracks/:id/link` — whether a link is out, never the link itself. */
export async function showLink(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, role } = trackAccess(ctx, user, trackId);
  requireOwner(role, "see this track's invite link");
  const link = ctx.db.linkOf(track.id);
  // The URL is deliberately absent. Only the hash is stored, so it genuinely
  // cannot be shown again — which is worth being honest about rather than
  // implying it was lost.
  return json({ data: link ? { url: null, createdAt: link.createdAt, expiresAt: link.expiresAt } : null });
}

/**
 * `POST /api/tracks/:id/link` — mint one, replacing whatever was out.
 *
 * Minting is also the revoke: there is one row per track, so a new link
 * silently kills the old one. That is the behaviour people expect from a
 * "regenerate" button and the one they do not expect from a "create" button,
 * so the UI says which it is doing.
 */
export async function mintLink(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, role } = trackAccess(ctx, user, trackId);
  requireOwner(role, "make an invite link for a track");

  const token = randomToken();
  ctx.db.putLink(track.id, await sha256(token), user.id, LINK_TTL_MS);
  const link = ctx.db.linkOf(track.id)!;
  return json({
    data: { url: `${ctx.config.publicUrl}/j/${token}`, createdAt: link.createdAt, expiresAt: link.expiresAt },
  }, 201);
}

/** `DELETE /api/tracks/:id/link` — nobody new gets in on it. */
export async function dropLink(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, role } = trackAccess(ctx, user, trackId);
  requireOwner(role, "revoke this track's invite link");
  ctx.db.dropLink(track.id);
  // Deliberately not a removal: people who already came in on this link stay,
  // and the owner takes them out by name if that is what they meant. A revoke
  // that silently evicted half a track would be the more surprising of the two.
  return json({ data: null });
}

/** `GET /api/projects/:id/link` — whether a link is out, never the link itself. */
export async function showProjectLink(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { project, role } = projectAccess(ctx, user, projectId);
  requireOwner(role, "see this project's invite link");
  const link = ctx.db.projectLinkOf(project.id);
  return json({ data: link ? { url: null, createdAt: link.createdAt, expiresAt: link.expiresAt } : null });
}

/** `POST /api/projects/:id/link` — mint one, replacing whatever was out. */
export async function mintProjectLink(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { project, role } = projectAccess(ctx, user, projectId);
  requireOwner(role, "make an invite link for a project");

  const token = randomToken();
  ctx.db.putProjectLink(project.id, await sha256(token), user.id, PROJECT_LINK_TTL_MS);
  const link = ctx.db.projectLinkOf(project.id)!;
  return json({
    data: { url: `${ctx.config.publicUrl}/j/${token}`, createdAt: link.createdAt, expiresAt: link.expiresAt },
  }, 201);
}

/** `DELETE /api/projects/:id/link` — nobody new gets in on it. */
export async function dropProjectLink(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { project, role } = projectAccess(ctx, user, projectId);
  requireOwner(role, "revoke this project's invite link");
  ctx.db.dropProjectLink(project.id);
  return json({ data: null });
}

/**
 * A link token, spent.
 *
 * One function for both kinds because `/j/:token` is one route: the token says
 * which it is, and a browser holding one has no idea and should not need to.
 * Tracks are tried first only because they are the older and narrower of the
 * two — the hashes are unique across both tables, so the order is arbitrary
 * rather than load-bearing.
 *
 * Returns where to land, or null when the link is unknown, revoked, expired,
 * or points at something that has since closed.
 */
async function redeem(ctx: AppContext, userId: string, token: string): Promise<string | null> {
  const hash = await sha256(token);

  const track = ctx.db.trackForLink(hash);
  if (track) {
    const project = ctx.db.project(track.projectId);
    if (!project || project.archivedAt) return null;
    // Somebody already in the whole project needs no row and gets none: a
    // track membership written here would outlive their project membership
    // and quietly leave them one branch after being removed.
    if (project.userId !== userId && !ctx.db.isProjectMember(project.id, userId)) {
      ctx.db.addMember(track.id, userId, "link");
    }
    publish(project.id, { event: "people", data: { trackId: track.id } });
    return `/p/${project.id}/t/${track.id}`;
  }

  const project = ctx.db.projectForLink(hash);
  if (project) {
    if (project.userId !== userId) ctx.db.addProjectMember(project.id, userId, "link");
    publish(project.id, { event: "people", data: {} });
    // The project rather than one of its tracks: this link did not name one,
    // and picking a track for somebody is picking which of several
    // conversations they have walked into.
    return `/p/${project.id}`;
  }

  return null;
}

/**
 * `GET /j/:token` — somebody opening a link, of either kind.
 *
 * Signed in, they join and land. Signed out, the token is parked in the
 * one-use OAuth state and claimed on the way back from GitHub, because an
 * invitation that admitted anonymous browsers would be an invitation with
 * nobody's name on it — and the whole point of sharing this is that the
 * transcript says who asked.
 *
 * The signed-out branch does not check the token first. It used to, and that
 * was a way to ask whether a given token was live without ever signing in;
 * sending everyone to GitHub and deciding afterwards costs a stranger one
 * round trip and tells them nothing.
 */
export async function join(ctx: AppContext, req: Request, token: string): Promise<Response> {
  const session = cookieValue(req, SESSION_COOKIE);
  const user = session ? ctx.db.sessionUser(await sha256(session)) : null;
  if (!user) {
    const gh = requireGitHub(ctx);
    const state = randomToken(18);
    ctx.db.putState(state, "join", token);
    return seeOther(gh.authorizeUrl(callbackUrl(ctx), state));
  }

  const landing = await redeem(ctx, user.id, token);
  return seeOther(landing ?? "/?error=bad_invite");
}

/** Claim a link token on the sign-in it triggered. Returns where to land. */
export async function claimLink(ctx: AppContext, userId: string, token: string): Promise<string | null> {
  return await redeem(ctx, userId, token);
}

function seeOther(location: string): Response {
  return new Response(null, { status: 303, headers: { location } });
}

function toPerson(u: UserRow): Person {
  return { login: u.login, name: u.name, avatarUrl: u.avatarUrl };
}
