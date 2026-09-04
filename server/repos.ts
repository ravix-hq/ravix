/**
 * GitHub, as the browser sees it.
 *
 * Four lists and a report, all read through the server because the browser
 * holds no GitHub credential either. Which of the two credentials each one
 * uses is a real distinction and not an implementation detail:
 *
 *   the **user's** token   answers "what may *you* see" — installations, and
 *                          the repositories inside them. Asking the App this
 *                          would list every account that ever installed
 *                          switchyard.
 *   the **installation's** token answers "what is *in* it" — branches, pull
 *                          requests, issues, checks. Asking as the user would
 *                          work and would be wrong: it would succeed for
 *                          repositories the installation does not grant, which
 *                          is precisely the boundary the App exists to draw.
 */
import type { AppContext } from "./context";
import { authenticate, projectOf, requireGitHub, trackAccess, userToken } from "./context";
import { asHttpError } from "./github";
import { HttpError, json, readJson, str } from "./http";

/** `GET /api/github/repos?installation=` — the picker's list. */
export async function repos(ctx: AppContext, req: Request): Promise<Response> {
  const gh = requireGitHub(ctx);
  const user = await authenticate(ctx, req);
  const token = await userToken(ctx, user);
  const wanted = Number(new URL(req.url).searchParams.get("installation")) || null;

  try {
    const installations = await gh.installationsFor(token);
    // No installation at all is not an error: it is the state everybody is in
    // before they grant access, and the picker renders an invitation to do so.
    if (!installations.length) return json({ data: { installations: [], repos: [] } });
    const chosen = wanted && installations.some((i) => i.id === wanted) ? wanted : installations[0]!.id;
    const list = await gh.repositories(token, chosen);
    return json({ data: { installations, selected: chosen, repos: list } });
  } catch (err) {
    throw asHttpError(err, "list your repositories");
  }
}

/**
 * `GET /api/projects/:id/refs?kind=` — the three tabs of "create from…".
 *
 * One route rather than three because the picker switches tabs without
 * changing what it is asking about, and three endpoints would be three places
 * to forget the installation check.
 */
export async function refs(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const gh = requireGitHub(ctx);
  const user = await authenticate(ctx, req);
  const project = projectOf(ctx, user, projectId);
  if (!project.repoFullName || !project.installationId) {
    throw new HttpError(409, "no_repo", "This project has no repository, so there is nothing to start from.");
  }
  const kind = new URL(req.url).searchParams.get("kind") ?? "branches";
  try {
    if (kind === "pulls") return json({ data: await gh.pulls(project.installationId, project.repoFullName) });
    if (kind === "issues") return json({ data: await gh.issues(project.installationId, project.repoFullName) });
    return json({
      data: await gh.branches(project.installationId, project.repoFullName, project.defaultBranch ?? "main"),
    });
  } catch (err) {
    throw asHttpError(err, "read that repository");
  }
}

/**
 * `GET /api/tracks/:id/checks` — the Checks tab.
 *
 * A branch that has never been pushed is the ordinary state of a new track,
 * and `pushed: false` says so rather than returning an empty list that looks
 * like a failure with no runs.
 */
export async function checks(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const gh = requireGitHub(ctx);
  const user = await authenticate(ctx, req);
  // A member's own branch and its checks are the point of inviting them, so
  // this is track access rather than project ownership.
  const { track, project } = trackAccess(ctx, user, trackId);
  if (!project.repoFullName || !project.installationId) {
    throw new HttpError(409, "no_repo", "This project has no repository.");
  }
  try {
    return json({ data: await gh.checks(project.installationId, project.repoFullName, track.branch) });
  } catch (err) {
    throw asHttpError(err, "read this branch's checks");
  }
}

/**
 * `POST /api/tracks/:id/pull` — open a pull request for this track's branch.
 *
 * Switchyard opens it rather than asking the agent to, when the agent has no
 * `gh` on the box. The distinction matters for who it comes from: this one is
 * authored by the App, which is honest — a machine opened it — where a token
 * borrowed from the person would put their name on work they have not read.
 */
export async function openPull(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const gh = requireGitHub(ctx);
  const user = await authenticate(ctx, req);
  // Open to members, and that is a decision rather than an oversight: a member
  // can already prompt the agent, the machine already holds a credential that
  // can push, and the agent will open a pull request if asked. A button that
  // refused what the prompt box allows would be theatre. The invite dialog
  // says so where the decision is made.
  const { track, project } = trackAccess(ctx, user, trackId);
  if (!project.repoFullName || !project.installationId) throw new HttpError(409, "no_repo", "This project has no repository.");

  const body = await readJson(req);
  const title = str(body.title, 200).trim() || track.title;
  const base = str(body.base, 200).trim() || project.defaultBranch || "main";
  try {
    const pull = await gh.openPull(project.installationId, project.repoFullName, {
      head: track.branch,
      base,
      title,
      body: str(body.body, 20_000) || `Opened from switchyard track \`${track.slug}\`.`,
      draft: body.draft !== false,
    });
    return json({ data: pull }, 201);
  } catch (err) {
    throw asHttpError(err, "open a pull request");
  }
}
