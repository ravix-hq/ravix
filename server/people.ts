/**
 * Working on a track with somebody else.
 *
 * The unit of sharing is a **track**, not a project, and that is the whole
 * design rather than an implementation detail. A project is a machine with a
 * disk, a settings panel and a bill; a track is one branch in one directory.
 * Inviting somebody to a branch is a thing people do every day. Inviting them
 * to your machine is not, and an app that offered only the second would be
 * offering the wrong thing under the right name.
 *
 * So a member gets exactly the track they were named on: its transcript, its
 * files, its diff, its terminal, and the ability to prompt it. They do not see
 * the project's other tracks, cannot open one, cannot change what is installed
 * on the machine, and cannot close the track they are in. `trackAccess` in
 * `context.ts` enforces that by looking membership up per row.
 *
 * ## What sharing a track actually costs
 *
 * It is worth being exact, because the invite dialog says it and this is where
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
 * What they cannot do is reach the project's *controls*. That is a real line
 * and it is drawn in code. The one worth knowing is the credential: the clone
 * token lives in the vault and never lands on the machine, so a member cannot
 * print it — the machine does not have it to print.
 */
import type { Person } from "../shared/api";
import type { AppContext } from "./context";
import { authenticate, requireGitHub, requireOwner, trackAccess } from "./context";
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
  return json({ data: peopleOf(ctx, track.id, project.userId) });
}

/**
 * `POST /api/tracks/:id/people` — invite somebody by GitHub login.
 *
 * They must already have signed in here. Switchyard cannot invite a stranger:
 * it has no address to send anything to (sign-in is GitHub, and this app never
 * asks for an email), and a row naming a login that has never appeared would
 * be a permission granted to whoever claimed that name first.
 */
export async function add(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project, role } = trackAccess(ctx, user, trackId);
  requireOwner(role, "invite people to a track");

  const body = await readJson(req);
  const login = str(body.login, 80).trim().replace(/^@/, "");
  if (!login) throw new HttpError(422, "no_login", "Give a GitHub username.");

  // Somebody who has signed in here joins immediately.
  const existing = ctx.db.userByLogin(login);
  if (existing) {
    if (existing.id === project.userId) {
      throw new HttpError(422, "already_owner", "That is the owner of this project — they are already in every track of it.");
    }
    ctx.db.addMember(track.id, existing.id, user.id);
    publish(project.id, { event: "people", data: { trackId: track.id } });
    return json({ data: peopleOf(ctx, track.id, project.userId) }, 201);
  }

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
  if (String(account.id) === ctx.db.user(project.userId)?.githubId) {
    throw new HttpError(422, "already_owner", "That is the owner of this project — they are already in every track of it.");
  }

  ctx.db.addInvite({
    trackId: track.id,
    githubId: String(account.id),
    login: account.login,
    avatarUrl: account.avatar_url,
    invitedBy: user.id,
  });
  publish(project.id, { event: "people", data: { trackId: track.id } });
  return json({ data: peopleOf(ctx, track.id, project.userId) }, 201);
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
    return json({ data: peopleOf(ctx, track.id, project.userId) });
  }

  const target = ctx.db.userByLogin(wanted);
  if (!target) throw new HttpError(404, "not_found", "No such person on this track.");
  if (role !== "owner" && target.id !== user.id) {
    throw new HttpError(403, "owner_only", "Only the owner of this project can remove somebody else.");
  }

  ctx.db.removeMember(track.id, target.id);
  publish(project.id, { event: "people", data: { trackId: track.id } });
  // The caller may have just removed their own access, in which case there is
  // nothing left to hand back — 204 rather than a list they cannot see.
  if (target.id === user.id && role !== "owner") return new Response(null, { status: 204 });
  return json({ data: peopleOf(ctx, track.id, project.userId) });
}

/**
 * Everyone on a track, owner first.
 *
 * The owner is not a row in `track_members` — they own the project, which is a
 * stronger claim that survives every membership being deleted — so they are
 * prepended here rather than written into the table. A synthetic row would
 * have to be kept in step with the project's `user_id` forever, and the day it
 * was not, the owner would lose their own track.
 */
export function peopleOf(ctx: AppContext, trackId: string, ownerId: string): Person[] {
  const owner = ctx.db.user(ownerId);
  const members = ctx.db.membersOf(trackId);
  // Pending last, because they cannot read anything yet and the list is
  // mostly read to answer "who can see this".
  const pending = ctx.db.invitesOf(trackId).map((i) => ({ login: i.login, name: null, avatarUrl: i.avatarUrl, pending: true }));
  return [...(owner ? [owner] : []), ...members.map(toPerson), ...pending];
}

// ── the other way in: a link ───────────────────────────────────────────

/**
 * How long a link lasts.
 *
 * A week, because the thing it is for is "have a look at this with me", not
 * "here is standing access". A link that never expires is a credential
 * somebody pasted into a chat two years ago and forgot, and this one grants a
 * shell on a machine.
 */
const LINK_TTL_MS = 7 * 24 * 60 * 60 * 1000;

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

/**
 * `GET /j/:token` — somebody opening the link.
 *
 * Signed in, they join and land on the track. Signed out, the token is parked
 * in the one-use OAuth state and claimed on the way back from GitHub, because
 * an invitation that admitted anonymous browsers would be an invitation with
 * nobody's name on it — and the whole point of a shared track is that the
 * transcript says who asked.
 */
export async function join(ctx: AppContext, req: Request, token: string): Promise<Response> {
  const hash = await sha256(token);
  const track = ctx.db.trackForLink(hash);
  if (!track) return seeOther("/?error=bad_invite");

  const session = cookieValue(req, SESSION_COOKIE);
  const user = session ? ctx.db.sessionUser(await sha256(session)) : null;
  if (!user) {
    const gh = requireGitHub(ctx);
    const state = randomToken(18);
    ctx.db.putState(state, "join", token);
    return seeOther(gh.authorizeUrl(callbackUrl(ctx), state));
  }

  const project = ctx.db.project(track.projectId);
  if (!project || project.archivedAt) return seeOther("/?error=bad_invite");
  if (project.userId !== user.id) ctx.db.addMember(track.id, user.id, "link");
  publish(project.id, { event: "people", data: { trackId: track.id } });
  return seeOther(`/p/${project.id}/t/${track.id}`);
}

/** Claim a link token on the sign-in it triggered. Returns where to land. */
export async function claimLink(ctx: AppContext, userId: string, token: string): Promise<string | null> {
  const track = ctx.db.trackForLink(await sha256(token));
  if (!track) return null;
  const project = ctx.db.project(track.projectId);
  if (!project || project.archivedAt) return null;
  if (project.userId !== userId) ctx.db.addMember(track.id, userId, "link");
  publish(project.id, { event: "people", data: { trackId: track.id } });
  return `/p/${project.id}/t/${track.id}`;
}

function seeOther(location: string): Response {
  return new Response(null, { status: 303, headers: { location } });
}

function toPerson(u: UserRow): Person {
  return { login: u.login, name: u.name, avatarUrl: u.avatarUrl };
}
