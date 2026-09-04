/**
 * The routes.
 *
 *   GET    /healthz
 *
 *   GET    /api/session                     viewer, sign-in URL, what works here
 *   GET    /api/auth/callback               GitHub coming back, from either trip
 *   GET    /api/auth/install                go and grant repository access
 *   POST   /api/auth/signout
 *   GET    /api/github/installations
 *   GET    /api/github/repos                the repository picker
 *
 *   GET    /api/projects                    the sidebar
 *   POST   /api/projects                    a repository becomes a machine
 *   GET    /api/projects/:id
 *   DELETE /api/projects/:id
 *   GET    /api/projects/:id/settings
 *   PUT    /api/projects/:id/settings
 *   POST   /api/projects/:id/rebuild        new machine, same settings
 *   GET    /api/projects/:id/refs?kind=     branches | pulls | issues
 *   GET    /api/projects/:id/tracks
 *   POST   /api/projects/:id/tracks         a new line off the main
 *   GET    /api/projects/:id/stream         the set of tracks, live
 *
 *   GET    /api/tracks/:id                  the track and its ribbon
 *   PATCH  /api/tracks/:id                  rename
 *   DELETE /api/tracks/:id                  close, and remove the worktree
 *   POST   /api/tracks/:id/prompt
 *   POST   /api/tracks/:id/interrupt
 *   POST   /api/tracks/:id/retry            send the opening turn again
 *   GET    /api/tracks/:id/events           the transcript so far
 *   GET    /api/tracks/:id/stream           the transcript, live
 *   GET    /api/tracks/:id/files?path=      inside this worktree only
 *   GET    /api/tracks/:id/file?path=
 *   GET    /api/tracks/:id/diff
 *   GET    /api/tracks/:id/checks           GitHub's view of the branch
 *   POST   /api/tracks/:id/pull             open a pull request
 *   GET    /api/tracks/:id/exec             whether a terminal will work
 *   POST   /api/tracks/:id/exec             run one command on the machine
 *
 * The shape of this list is the permission model, and it is a much shorter
 * list than paddock's for one reason: **there is no Fountain proxy here at
 * all**. Paddock forwards a curated set of Fountain paths on the owner's key;
 * switchyard runs on *its own* key, shared by everybody, so forwarding
 * anything would be handing a stranger the account every machine on this
 * deployment is built on. Every route above is a typed operation on something
 * the caller owns, and `projectOf`/`trackOf` decide ownership by lookup rather
 * than by a check that could be forgotten.
 */
import type { AppContext } from "./context";
import { authenticate, projectOf } from "./context";
import * as auth from "./auth";
import * as projects from "./projects";
import * as repos from "./repos";
import * as terminal from "./terminal";
import * as tracks from "./tracks";
import { projectStream } from "./hub";
import { errorResponse, HttpError, json } from "./http";

type Handler = (req: Request, params: Record<string, string>) => Response | Promise<Response>;

interface Route {
  method: string;
  pattern: string[];
  handler: Handler;
}

export function buildRouter(ctx: AppContext): (req: Request) => Promise<Response> {
  const routes: Route[] = [];
  const on = (method: string, path: string, handler: Handler) => {
    routes.push({ method, pattern: path.split("/").filter(Boolean), handler });
  };

  on("GET", "/healthz", () => new Response("ok\n", { headers: { "content-type": "text/plain" } }));

  on("GET", "/api/session", (req) => auth.session(ctx, req));
  on("GET", "/api/auth/callback", (req) => auth.callback(ctx, req));
  on("GET", "/api/auth/install", (req) => auth.install(ctx, req));
  on("POST", "/api/auth/signout", (req) => auth.signOut(ctx, req));
  on("GET", "/api/github/installations", (req) => auth.installations(ctx, req));
  on("GET", "/api/github/repos", (req) => repos.repos(ctx, req));

  on("GET", "/api/projects", (req) => projects.list(ctx, req));
  on("POST", "/api/projects", (req) => projects.create(ctx, req));
  on("GET", "/api/projects/:id", (req, p) => projects.show(ctx, req, p.id!));
  on("DELETE", "/api/projects/:id", (req, p) => projects.destroy(ctx, req, p.id!));
  on("GET", "/api/projects/:id/settings", (req, p) => projects.settings(ctx, req, p.id!));
  on("PUT", "/api/projects/:id/settings", (req, p) => projects.updateSettings(ctx, req, p.id!));
  on("POST", "/api/projects/:id/rebuild", (req, p) => projects.rebuild(ctx, req, p.id!));
  on("GET", "/api/projects/:id/refs", (req, p) => repos.refs(ctx, req, p.id!));
  on("GET", "/api/projects/:id/tracks", (req, p) => tracks.list(ctx, req, p.id!));
  on("POST", "/api/projects/:id/tracks", (req, p) => tracks.open(ctx, req, p.id!));
  on("GET", "/api/projects/:id/stream", async (req, p) => {
    // Authorized before the stream opens, not inside it: a ReadableStream that
    // throws in `start` becomes a connection that closes with no status a
    // browser can read, and `EventSource` retries it forever.
    const user = await authenticate(ctx, req);
    const project = projectOf(ctx, user, p.id!);
    return projectStream(project.id, req.signal);
  });

  on("GET", "/api/tracks/:id", (req, p) => tracks.show(ctx, req, p.id!));
  on("PATCH", "/api/tracks/:id", (req, p) => tracks.rename(ctx, req, p.id!));
  on("DELETE", "/api/tracks/:id", (req, p) => tracks.close(ctx, req, p.id!));
  on("POST", "/api/tracks/:id/prompt", (req, p) => tracks.prompt(ctx, req, p.id!));
  on("POST", "/api/tracks/:id/interrupt", (req, p) => tracks.interrupt(ctx, req, p.id!));
  on("POST", "/api/tracks/:id/retry", (req, p) => tracks.retry(ctx, req, p.id!));
  on("GET", "/api/tracks/:id/events", (req, p) => tracks.events(ctx, req, p.id!));
  on("GET", "/api/tracks/:id/stream", (req, p) => tracks.stream(ctx, req, p.id!));
  on("GET", "/api/tracks/:id/files", (req, p) => tracks.files(ctx, req, p.id!));
  on("GET", "/api/tracks/:id/file", (req, p) => tracks.file(ctx, req, p.id!));
  on("GET", "/api/tracks/:id/diff", (req, p) => tracks.diff(ctx, req, p.id!));
  on("GET", "/api/tracks/:id/checks", (req, p) => repos.checks(ctx, req, p.id!));
  on("POST", "/api/tracks/:id/pull", (req, p) => repos.openPull(ctx, req, p.id!));
  on("GET", "/api/tracks/:id/exec", (req, p) => terminal.execStatus(ctx, req, p.id!));
  on("POST", "/api/tracks/:id/exec", (req, p) => terminal.exec(ctx, req, p.id!));

  return async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    const path = url.pathname;
    try {
      const segments = path.split("/").filter(Boolean);
      for (const route of routes) {
        if (route.method !== "*" && route.method !== req.method.toUpperCase()) continue;
        const params = match(route.pattern, segments);
        if (params) return await route.handler(req, params);
      }
      if (path.startsWith("/api/")) throw new HttpError(404, "not_found", `No route ${req.method} ${path}.`);
      return await serveStatic(ctx, path);
    } catch (err) {
      return errorResponse(err);
    }
  };
}

/** `:name` captures a segment; a trailing `*` captures the rest as `rest`. */
function match(pattern: string[], segments: string[]): Record<string, string> | null {
  const params: Record<string, string> = {};
  for (let i = 0; i < pattern.length; i++) {
    const part = pattern[i]!;
    if (part === "*") {
      params.rest = segments.slice(i).join("/");
      return params;
    }
    const seg = segments[i];
    if (seg === undefined) return null;
    if (part.startsWith(":")) params[part.slice(1)] = decodeURIComponent(seg);
    else if (part !== seg) return null;
  }
  return segments.length === pattern.length ? params : null;
}

/** The built SPA, with the usual fallback so client-side routing works. */
async function serveStatic(ctx: AppContext, path: string): Promise<Response> {
  if (!ctx.config.staticDir) return json({ error: "not_found" }, 404);
  const rel = path === "/" ? "index.html" : path.replace(/^\/+/, "");
  if (rel.includes("..")) return json({ error: "not_found" }, 404);
  const file = Bun.file(`${ctx.config.staticDir}/${rel}`);
  if (await file.exists()) return new Response(file);
  const index = Bun.file(`${ctx.config.staticDir}/index.html`);
  if (await index.exists()) return new Response(index, { headers: { "content-type": "text/html; charset=utf-8" } });
  return json({ error: "not_found" }, 404);
}
