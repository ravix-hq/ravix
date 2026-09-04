/**
 * Who is asking, and what they are allowed to touch.
 *
 * Shorter than paddock's equivalent, and the difference is worth naming:
 * paddock admits people with no account at all, so identity there is a union
 * and every route downstream has to handle both halves. Switchyard has one
 * kind of caller — somebody signed in with GitHub — and one rule: you reach
 * your own projects and no others.
 *
 * That rule is enforced by lookup rather than by a check. `projectOf` selects
 * on `user_id` as well as `id`, so a project belonging to somebody else is not
 * refused, it is *not found* — which is the honest answer, since its existence
 * is not the caller's to learn.
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

/** One of the caller's projects. 404 for anyone else's. */
export function projectOf(ctx: AppContext, user: UserRow, projectId: string): ProjectRow {
  const project = ctx.db.project(projectId);
  if (!project || project.userId !== user.id || project.archivedAt) {
    throw new HttpError(404, "not_found", "No such project.");
  }
  return project;
}

/** One track of one of the caller's projects, and the project it belongs to. */
export function trackOf(ctx: AppContext, user: UserRow, trackId: string): { track: TrackRow; project: ProjectRow } {
  const track = ctx.db.track(trackId);
  if (!track) throw new HttpError(404, "not_found", "No such track.");
  const project = projectOf(ctx, user, track.projectId);
  return { track, project };
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
