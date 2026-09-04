/**
 * Who is asking, and what they are allowed to touch.
 *
 * Shorter than paddock's equivalent, and the difference is worth naming:
 * paddock admits people with no account at all, so identity there is a union
 * and every route downstream has to handle both halves. Switchyard has one
 * kind of caller — somebody signed in with GitHub — and three doors, in
 * widening order:
 *
 *   `trackAccess`    one branch, because you were named on it
 *   `projectAccess`  every branch on a machine, because you were named on it
 *   `projectOf`      the machine itself, because you own it
 *
 * All three are enforced by lookup rather than by a check, and all three answer
 * *not found* rather than refusing: the existence of somebody else's project is
 * not the caller's to learn.
 */
import type { Config } from "./config";
import type { Cipher } from "./crypto";
import { sha256 } from "./crypto";
import type { Db, ProjectRow, TrackRow, UserRow } from "./db";
import { Fountain } from "./fountain";
import { GitHub } from "./github";
import { Sprites } from "./sprites";
import { HttpError, SESSION_COOKIE, cookieValue } from "./http";

export interface AppContext {
  db: Db;
  cipher: Cipher;
  config: Config;
  /** Null when this deployment has no Fountain key — the app then has no machines. */
  fountain: Fountain | null;
  /** Null when the GitHub App is not configured. */
  github: GitHub | null;
  /** Null when there is no Sprites token — the terminal and run panels say so. */
  sprites: Sprites | null;
}

export function buildContext(input: { db: Db; cipher: Cipher; config: Config }): AppContext {
  const { config } = input;
  return {
    ...input,
    fountain: config.fountainKey ? new Fountain(config.fountainUrl, config.fountainKey) : null,
    github: config.github ? new GitHub(config.github) : null,
    sprites: config.sprites ? new Sprites(config.sprites) : null,
  };
}

/** The signed-in user. 401 when there is none. */
export async function authenticate(ctx: AppContext, req: Request): Promise<UserRow> {
  const token = cookieValue(req, SESSION_COOKIE);
  if (!token) throw new HttpError(401, "unauthenticated", "Sign in with GitHub.");
  const user = ctx.db.sessionUser(await sha256(token));
  if (!user) throw new HttpError(401, "unauthenticated", "That session has ended. Sign in again.");
  return user;
}

/**
 * A project the caller **owns**. 404 for anyone else's.
 *
 * The project's *controls* go through this and nothing else: its settings, its
 * packages and secrets, the rebuild, and the delete. Somebody invited to the
 * project is not a caller here — they are a caller at `projectAccess` — and
 * gets the same answer as a stranger, because a machine you were let onto is
 * still not a machine you get to re-provision.
 */
export function projectOf(ctx: AppContext, user: UserRow, projectId: string): ProjectRow {
  const project = ctx.db.project(projectId);
  if (!project || project.userId !== user.id || project.archivedAt) {
    throw new HttpError(404, "not_found", "No such project.");
  }
  return project;
}

/** Owner, or somebody invited to the track or the project in question. */
export type Role = "owner" | "member";

export interface ProjectAccess {
  project: ProjectRow;
  role: Role;
}

/**
 * A project the caller may work in, and in what capacity.
 *
 * The wider door, and the one added when "invite somebody to the whole
 * project" became a thing switchyard can do. A project member reaches every
 * track on it — the ones open now and the ones opened tomorrow — and may cut
 * tracks of their own, because a project you were let into where you cannot
 * start a line of work is only a bundle of track invitations with a nicer
 * name.
 *
 * What it is *not* is `projectOf`. The line between the two is the line the
 * README draws: the work on the machine is shared, the machine is not. So the
 * settings panel, the package list, the secrets, the rebuild and the delete
 * all keep resolving through `projectOf` and refuse a member exactly as they
 * refuse a stranger.
 */
export function projectAccess(ctx: AppContext, user: UserRow, projectId: string): ProjectAccess {
  const project = ctx.db.project(projectId);
  if (!project || project.archivedAt) throw new HttpError(404, "not_found", "No such project.");
  if (project.userId === user.id) return { project, role: "owner" };
  if (ctx.db.isProjectMember(project.id, user.id)) return { project, role: "member" };
  throw new HttpError(404, "not_found", "No such project.");
}

export interface TrackAccess {
  track: TrackRow;
  project: ProjectRow;
  role: Role;
}

/**
 * A track the caller may reach, and in what capacity.
 *
 * Two ways in, and the order they are tried in is the order of how much they
 * grant. Somebody named on *this track* gets this track: a second track of the
 * same project lands here again and is refused again, which is what makes "an
 * invitation is to a branch, not to the machine" true by construction rather
 * than by everybody remembering. Somebody invited to the **project** gets all
 * of them, which is the point of that invitation and is why it is a separate,
 * deliberate act by the owner rather than something a track invite grows into.
 *
 * Both come back as `member`. The distinction between them is about how they
 * got here, not about what they may do once they are, and every route below
 * this one wants the second question.
 *
 * A project that has been archived is gone for its members too, and a closed
 * track stops admitting anyone: neither has a surface left to share.
 */
export function trackAccess(ctx: AppContext, user: UserRow, trackId: string): TrackAccess {
  const track = ctx.db.track(trackId);
  if (!track) throw new HttpError(404, "not_found", "No such track.");
  const project = ctx.db.project(track.projectId);
  if (!project || project.archivedAt) throw new HttpError(404, "not_found", "No such track.");

  if (project.userId === user.id) return { track, project, role: "owner" };
  if (track.closedAt) throw new HttpError(404, "not_found", "No such track.");
  if (ctx.db.isMember(track.id, user.id)) return { track, project, role: "member" };
  if (ctx.db.isProjectMember(project.id, user.id)) return { track, project, role: "member" };
  throw new HttpError(404, "not_found", "No such track.");
}

/** The same, refusing anyone but the owner. For closing, renaming, and settings. */
export function trackOf(ctx: AppContext, user: UserRow, trackId: string): TrackAccess {
  const access = trackAccess(ctx, user, trackId);
  return access;
}

/** Owner-only operations on a track somebody else may also be in. */
export function requireOwner(role: Role, what: string): void {
  if (role !== "owner") throw new HttpError(403, "owner_only", `Only the owner of this project can ${what}.`);
}

/**
 * The same, plus whoever cut the track.
 *
 * For renaming and closing, and it exists because project members can open
 * tracks. Somebody who may make a directory on the machine and then may not
 * tidy it up leaves the owner sweeping up after their guests, which is a worse
 * outcome than the one owner-only was protecting against. It is still not "any
 * member": being invited to help on a branch is not being handed the ability
 * to end it for everybody else in it.
 *
 * Matched on the login rather than a user id because that is what the row
 * holds — `created_by_login` is written for the ribbon, and the person who
 * renames their GitHub account is a rarer event than the one this prevents.
 */
export function requireOwnerOrCutter(role: Role, user: UserRow, track: TrackRow, what: string): void {
  if (role === "owner") return;
  if (track.createdByLogin.toLowerCase() === user.login.toLowerCase()) return;
  throw new HttpError(403, "owner_only", `Only the owner of this project, or whoever opened this track, can ${what}.`);
}

/**
 * The Fountain client, or a refusal that says what is missing.
 *
 * A deployment with no `FOUNTAIN_API_KEY` can still sign people in and show
 * them their repositories — which is enough of the app working to be
 * confusing. So the failure is named rather than generic: this is the one
 * variable without which switchyard has no machines at all.
 */
export function requireFountain(ctx: AppContext): Fountain {
  if (!ctx.fountain) {
    throw new HttpError(503, "no_fountain", "This switchyard has no Fountain account configured, so it cannot build machines.");
  }
  return ctx.fountain;
}

export function requireGitHub(ctx: AppContext): GitHub {
  if (!ctx.github) {
    throw new HttpError(503, "no_github", "This switchyard has no GitHub App configured, so it cannot see repositories.");
  }
  return ctx.github;
}

/**
 * The Sprites client, or the refusal the terminal panel renders as an empty
 * state rather than as an error. Distinguished from the others because this
 * one is genuinely optional and the UI is designed for its absence.
 */
export function requireSprites(ctx: AppContext): Sprites {
  if (!ctx.sprites) {
    throw new HttpError(501, "no_exec", "This switchyard has no Sprites token, so it cannot run commands on the machine directly.");
  }
  return ctx.sprites;
}

/** The user's GitHub OAuth token, decrypted. Used for anything read as *them*. */
export async function userToken(ctx: AppContext, user: UserRow): Promise<string> {
  if (!user.tokenEnc) throw new HttpError(401, "reauthenticate", "Sign in with GitHub again.");
  try {
    return await ctx.cipher.decrypt(user.tokenEnc);
  } catch {
    throw new HttpError(401, "reauthenticate", "Sign in with GitHub again.");
  }
}
