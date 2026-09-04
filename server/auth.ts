/**
 * Signing in, which here is two round trips to GitHub rather than one.
 *
 * **Authorize** gets an identity: who you are, and a token that speaks as you.
 * **Install** gets access: which repositories switchyard may see. They are
 * separate on purpose and in that order, because the second one is a decision
 * a person makes about their code and it should be made by somebody the app
 * can already name.
 *
 * A person can be signed in with no installation. That is not a broken state
 * and the UI does not treat it as one — it is the state everybody is in for
 * the ten seconds between the two, and the state anybody who declines stays
 * in. `Viewer.hasInstallation` is how the shell knows which of the two home
 * screens to render.
 */
import { randomToken, sha256 } from "./crypto";
import type { AppContext } from "./context";
import { authenticate, requireGitHub, userToken } from "./context";
import { GitHubError, asHttpError } from "./github";
import { claimLink } from "./people";
import type { Capabilities, SessionInfo, Viewer } from "../shared/api";
import { SESSION_COOKIE, clearedSessionCookie, cookieValue, json, sessionCookie } from "./http";

/** Where GitHub sends a browser back to. Registered on the App; must match exactly. */
export function callbackUrl(ctx: AppContext): string {
  return `${ctx.config.publicUrl}/api/auth/callback`;
}

/**
 * `GET /api/session` — everything the shell needs before its first render.
 *
 * One call rather than three (who am I, may I sign in, what works here)
 * because the answer to all three changes together and a shell that renders
 * from two of them has a frame where it disagrees with itself.
 */
export async function session(ctx: AppContext, req: Request): Promise<Response> {
  const capabilities: Capabilities = {
    exec: !!ctx.sprites,
    github: !!ctx.github,
    // Settled once at boot rather than probed per request: a Fountain that
    // does vaults today does them at midnight too.
    vaults: !!ctx.fountain,
  };
  const gh = ctx.github;
  const state = randomToken(18);
  if (gh) ctx.db.putState(state, "signin", null);

  const info: SessionInfo = {
    viewer: await viewerOf(ctx, req),
    signInUrl: gh ? gh.authorizeUrl(callbackUrl(ctx), state) : "",
    installUrl: gh ? gh.installUrl() : "",
    capabilities,
  };
  return json({ data: info });
}

async function viewerOf(ctx: AppContext, req: Request): Promise<Viewer | null> {
  const token = cookieValue(req, SESSION_COOKIE);
  if (!token) return null;
  const user = ctx.db.sessionUser(await sha256(token));
  if (!user) return null;

  // Asked live rather than stored, because it is a fact about GitHub that
  // changes without telling us: somebody installs the App in another tab, or
  // an admin removes it. A cached `true` here is a repository picker that
  // renders empty with no explanation.
  let hasInstallation = false;
  if (ctx.github && user.tokenEnc) {
    try {
      const list = await ctx.github.installationsFor(await ctx.cipher.decrypt(user.tokenEnc));
      hasInstallation = list.length > 0;
    } catch {
      // A revoked or expired user token. Not fatal to the session: the shell
      // shows the install prompt, and the first real call re-authenticates.
      hasInstallation = false;
    }
  }

  return {
    id: user.githubId,
    login: user.login,
    name: user.name,
    avatarUrl: user.avatarUrl,
    hasInstallation,
  };
}

/**
 * `GET /api/auth/callback` — GitHub coming back, from either round trip.
 *
 * Both land here. The sign-in flow arrives with `code` and our `state`; the
 * installation flow arrives with `installation_id` and `setup_action` and,
 * because the App's setup URL is this same path, sometimes with a `code` as
 * well. Handling them in one place is what makes "install, then sign in" and
 * "sign in, then install" both end at the same screen.
 *
 * The response is a redirect rather than JSON: this URL is opened by a browser
 * following GitHub, not by the SPA's fetch.
 */
export async function callback(ctx: AppContext, req: Request): Promise<Response> {
  const gh = requireGitHub(ctx);
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const installationId = url.searchParams.get("installation_id");

  // An installation with no code: the person was already signed in and just
  // granted repository access. Nothing to exchange — send them back in.
  if (!code) {
    return redirect(installationId ? "/?installed=1" : "/?error=github_declined");
  }

  // The state is one-use. A replayed callback finds nothing and is refused,
  // which is the entire defence against a login CSRF here. It also carries
  // the invite token, when this sign-in was started by somebody opening a
  // link — see `people.join`.
  const parked = state ? ctx.db.takeState(state) : null;
  if (!parked) {
    return redirect("/?error=stale_signin");
  }

  let token: string;
  let profile: { id: number; login: string; name: string | null; avatar_url: string };
  try {
    token = await gh.exchangeCode(code, callbackUrl(ctx));
    profile = await gh.viewer(token);
  } catch (err) {
    if (err instanceof GitHubError) return redirect(`/?error=${encodeURIComponent("github_" + err.status)}`);
    throw asHttpError(err, "sign you in");
  }

  const user = ctx.db.upsertUser({
    githubId: String(profile.id),
    login: profile.login,
    name: profile.name,
    avatarUrl: profile.avatar_url,
    tokenEnc: await ctx.cipher.encrypt(token),
  });

  const sessionToken = randomToken();
  ctx.db.createSession(user.id, await sha256(sessionToken), ctx.config.sessionMaxAgeMs);
  const cookie = { "set-cookie": sessionCookie(sessionToken, req, Math.floor(ctx.config.sessionMaxAgeMs / 1000)) };

  // Anything that was waiting for this person becomes real on the sign-in that
  // proves who they are, and not before. Two sources: invitations sent to
  // their GitHub account before they had one here, and the link that sent them
  // to GitHub in the first place.
  const joined = ctx.db.claimInvites(user.id, String(profile.id));
  if (parked.kind === "join" && parked.redirect) {
    const landing = await claimLink(ctx, user.id, parked.redirect);
    if (landing) return redirect(landing, cookie);
    return redirect("/?error=bad_invite", cookie);
  }

  // One invitation is worth landing on; several is a decision, so the rail is
  // the better place to make it. A project counts as one thing to arrive at
  // even when it brought several tracks with it, and it wins over a track:
  // whoever sent it meant the machine rather than a branch of it.
  const onlyProject = joined.projects.length === 1 && !joined.tracks.length ? joined.projects[0]! : null;
  if (onlyProject) return redirect(`/p/${onlyProject.id}`, cookie);
  const onlyTrack = !joined.projects.length && joined.tracks.length === 1 ? joined.tracks[0]! : null;
  if (onlyTrack) return redirect(`/p/${onlyTrack.projectId}/t/${onlyTrack.id}`, cookie);
  return redirect(installationId ? "/?installed=1" : "/", cookie);
}

/**
 * `GET /api/auth/install` — a signed-in person going to grant repository
 * access, with a state so the return trip is recognisable.
 *
 * A redirect rather than a link the SPA builds, because the state has to be
 * minted server-side and handing the browser a URL it did not ask for is how
 * an installation ends up attributed to the wrong account.
 */
export async function install(ctx: AppContext, req: Request): Promise<Response> {
  const gh = requireGitHub(ctx);
  await authenticate(ctx, req);
  const state = randomToken(18);
  ctx.db.putState(state, "install", null);
  return redirect(gh.installUrl(state));
}

export async function signOut(ctx: AppContext, req: Request): Promise<Response> {
  const token = cookieValue(req, SESSION_COOKIE);
  if (token) ctx.db.endSession(await sha256(token));
  return json({ data: { ok: true } }, 200, { "set-cookie": clearedSessionCookie(req) });
}

/**
 * `GET /api/github/installations` — the accounts this person has installed
 * the App on, so a repository picker can say whose repositories it is showing
 * and offer to add another.
 */
export async function installations(ctx: AppContext, req: Request): Promise<Response> {
  const gh = requireGitHub(ctx);
  const user = await authenticate(ctx, req);
  try {
    return json({ data: await gh.installationsFor(await userToken(ctx, user)) });
  } catch (err) {
    throw asHttpError(err, "list your installations");
  }
}

function redirect(location: string, headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 302, headers: { location, ...headers } });
}
