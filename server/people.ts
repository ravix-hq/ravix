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
import { authenticate, requireOwner, trackAccess } from "./context";
import type { UserRow } from "./db";
import { HttpError, json, readJson, str } from "./http";
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

  const invitee = ctx.db.userByLogin(login);
  if (!invitee) {
    throw new HttpError(404, "no_such_user", `@${login} has not signed in to switchyard, so there is nobody here to invite.`);
  }
  if (invitee.id === project.userId) {
    throw new HttpError(422, "already_owner", "That is the owner of this project — they are already in every track of it.");
  }

  ctx.db.addMember(track.id, invitee.id, user.id);
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

  const target = ctx.db.userByLogin(login.replace(/^@/, ""));
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
  return [...(owner ? [owner] : []), ...members].map(toPerson);
}

function toPerson(u: UserRow): Person {
  return { login: u.login, name: u.name, avatarUrl: u.avatarUrl };
}
