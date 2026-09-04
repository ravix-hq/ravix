/**
 * Tracks: a worktree, and a conversation about it.
 *
 * Everything difficult about this app is in `open` below, and it comes down to
 * one asymmetry. Making a *conversation* is an API call and takes a moment.
 * Making a *worktree* is work on a real machine and takes a turn. The two
 * cannot be done atomically, so a track exists in the UI before its directory
 * exists on the box, and pretending otherwise would mean either a spinner
 * covering the first ten seconds of every track or a prompt box that silently
 * fails until the machine catches up.
 *
 * So the opening turn is a real turn, sent immediately, and the person watches
 * it happen in the transcript. That is not a workaround — it is the same
 * decision paddock made about first run, for the same reason: the first thing
 * somebody sees is the machine actually doing their work, which is the
 * product. The track is `opening` until the machine answers and `ready`
 * afterwards, and the composer is live the whole time because Fountain queues
 * a prompt behind the turn already running.
 */
import { randomUUID } from "node:crypto";
import type { Person, Track, TrackHeader, TrackOriginInfo, TranscriptPage } from "../shared/api";
import { branchFor, mountPathFor, slugify, trackChannel, workdirFor } from "../shared/ids";
import { withAuthor } from "../shared/author";
import { nameTrack } from "../shared/names";
import { closeTrackPrompt, openTrackPrompt, starters, type TrackOrigin } from "../shared/spec";
import type { AppContext } from "./context";
import { authenticate, projectAccess, requireFountain, requireOwnerOrCutter, trackOf } from "./context";
import type { ProjectRow, TrackRow } from "./db";
import { originOf } from "./db";
import type { ConversationSummary, Fountain } from "./fountain";
import { asHttpError } from "./fountain";
import { accessOf, prepareMachine } from "./projects";
import { HttpError, json, readJson, str } from "./http";
import { peopleOf } from "./people";
import { publish } from "./hub";
import { beat, leave } from "./presence";

/** `GET /api/projects/:id/tracks` */
export async function list(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const project = ctx.db.project(projectId);
  if (!project || project.archivedAt) throw new HttpError(404, "not_found", "No such project.");

  // The owner and anybody invited to the whole project see all of its tracks.
  // Somebody invited to particular tracks sees those and is not told there are
  // others. Same list endpoint, because the sidebar asks the same question
  // whichever of the three is asking.
  const access = accessOf(ctx, user.id, project);
  const wide = access === "owner" || access === "project";
  const rows = wide ? ctx.db.tracksOf(project.id) : ctx.db.memberTracks(user.id).filter((t) => t.projectId === project.id);
  if (!access || (!wide && !rows.length)) throw new HttpError(404, "not_found", "No such project.");
  const owner = access === "owner";

  const live = await conversationsOf(ctx, project);
  const reads = ctx.db.readsOf(user.id, project.id);
  return json({
    data: rows.map((r) =>
      toTrack(
        r,
        project,
        live.get(r.conversationId ?? "") ?? null,
        peopleOf(ctx, r.id, project.userId, project.id),
        owner ? "owner" : "member",
        reads.get(r.id) ?? null,
      ),
    ),
  });
}

/** `GET /api/tracks/:id` — the track, plus the ribbon that sits above it. */
export async function show(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project, role } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  // The environment is read for one boolean, and it is worth the call: the
  // "add a setup script" line in the ribbon is an offer, and an offer that
  // keeps appearing after you have accepted it reads as a broken app.
  const [live, environment] = await Promise.all([
    conversationsOf(ctx, project),
    fountain.getEnvironment(project.environmentId).catch(() => null),
  ]);
  const header: TrackHeader = {
    copyOf: project.repoFullName ? project.repoFullName.split("/").pop()! : null,
    branchedFrom: track.originBase ? { branch: track.branch, base: track.originBase } : null,
    // The file count Conductor shows comes from copying a directory. Nothing
    // here copies anything — a worktree shares the object store — so the honest
    // answer is the directory alone rather than a number invented to match a
    // screenshot.
    created: { dir: track.slug, files: null },
    hasSetupScript: !!environment?.setup_script?.trim(),
  };
  return json({
    data: {
      track: toTrack(
        track,
        project,
        live.get(track.conversationId ?? "") ?? null,
        peopleOf(ctx, track.id, project.userId, project.id),
        role,
        ctx.db.lastReadOf(track.id, user.id),
      ),
      header,
      starters: starters({ hasRepo: !!project.repoFullName }),
    },
  });
}

/**
 * `POST /api/projects/:id/tracks` — a new line off the main.
 *
 * The four ways in (blank, a branch, a pull request, an issue) differ only in
 * what the opening turn is told, which is why they are one route with an
 * `origin` rather than four. The slug is derived from whatever the origin
 * names — a PR's title, a branch's name — because a person naming a directory
 * before they have started work is a question with no good answer.
 *
 * Open to project members as well as to the owner. Cutting a track is the work
 * rather than the machine — it makes a directory and a branch, and changes
 * nothing about what is installed or what the box holds — so it sits on the
 * `projectAccess` side of the line. The branch carries the *cutter's* login,
 * not the owner's, so the yard reads as who did what.
 */
export async function open(ctx: AppContext, req: Request, projectId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { project } = projectAccess(ctx, user, projectId);
  const fountain = requireFountain(ctx);
  const body = await readJson(req);

  const origin = readOrigin(body, project);
  // Every track this project has ever had, closed ones included — see
  // `nameTrack` for why a closed track's name is still spent.
  const taken = ctx.db.tracksOf(project.id, true).map((t) => t.slug);
  const title = str(body.title, 200).trim() || defaultTitle(origin, taken);
  const slug = freeSlug(ctx, project.id, str(body.slug, 60).trim() || title);
  const branch = origin.kind === "pr" && origin.base ? origin.base : branchFor(user.login, slug);
  const workdir = workdirFor(slug);

  // Before anything wakes the box: the clone token expires in an hour, and
  // this is a path that is about to make the machine talk to GitHub.
  await prepareMachine(ctx, project, fountain);

  // Attach to the machine that is already there, if there is one. The whole
  // identity goes on the attach — see `Fountain.createConversation` for why
  // half of it hands you a second machine instead of an error.
  const machine = await machineOf(fountain, project);
  const channel = trackChannel(project.id, slug, project.rev);

  const opening = openTrackPrompt({
    slug,
    branch,
    repoPath: project.repoFullName ? mountPathFor(project.repoFullName) : null,
    origin,
  });

  let conversationId: string;
  try {
    const conversation = await fountain.createConversation({
      agent_id: project.agentId,
      environment_id: project.environmentId,
      vault_id: project.vaultId,
      sandbox_id: machine?.sandboxId ?? null,
      title,
      channel_id: channel,
      // On the launch that *provisions* the machine the opening turn rides
      // along, because a fresh conversation with no prompt is what made
      // provisioning start answering 422. On an attach it is sent separately
      // below, where a machine at capacity can be reported and retried.
      ...(machine ? {} : { prompt: opening }),
    });
    conversationId = conversation.id;
  } catch (err) {
    throw asHttpError(err, "open this track");
  }

  const row = ctx.db.createTrack({
    id: randomUUID(),
    projectId: project.id,
    conversationId,
    slug,
    title,
    branch,
    workdir,
    originKind: origin.kind,
    originBase: origin.base,
    originNumber: origin.number ?? null,
    originTitle: origin.title ?? null,
    originUrl: originUrl(project, origin),
    rev: project.rev,
    createdByLogin: user.login,
  });

  if (machine) {
    // The opening turn, not awaited. It is a turn on a machine that may still
    // be booting, so it can take a minute — and the browser is already watching
    // the transcript it will appear in. Awaiting it here would hold the POST
    // open for the whole of the thing the person came to watch.
    void sendOpeningTurn(ctx, fountain, row, project, origin);
  } else {
    // It went with the launch. The track is open as far as Fountain is
    // concerned; the worktree lands when that turn does.
    ctx.db.markOpened(row.id);
  }

  publish(project.id, { event: "tracks", data: { projectId: project.id } });
  return json({ data: toTrack(row, project, null) }, 201);
}

async function sendOpeningTurn(
  ctx: AppContext,
  fountain: Fountain,
  track: TrackRow,
  project: ProjectRow,
  origin: TrackOrigin,
): Promise<void> {
  if (!track.conversationId) return;
  const prompt = openTrackPrompt({
    slug: track.slug,
    branch: track.branch,
    repoPath: project.repoFullName ? mountPathFor(project.repoFullName) : null,
    origin,
  });
  try {
    await fountain.prompt(track.conversationId, prompt);
    ctx.db.markOpened(track.id);
    publish(project.id, { event: "turn", data: { trackId: track.id, status: "ready" } });
  } catch (err) {
    // A machine at capacity is the ordinary case when two tracks are opened at
    // once: the box runs one turn at a time. Fountain queues it, so this is not
    // the failure it looks like — but a track whose worktree was never cut is
    // one a person needs to be able to retry, which `POST /retry` is for.
    console.error(`switchyard: opening turn for track ${track.id} did not send:`, err instanceof Error ? err.message : err);
    publish(project.id, { event: "turn", data: { trackId: track.id, status: "failed" } });
  }
}

/** `POST /api/tracks/:id/retry` — send the opening turn again. */
export async function retry(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  await prepareMachine(ctx, project, fountain);
  await sendOpeningTurn(ctx, fountain, track, project, originOf(track) as TrackOrigin);
  return json({ data: { ok: true } });
}

/**
 * `POST /api/tracks/:id/prompt` — a turn from a person.
 *
 * The clone token is re-minted first for the same reason it is on `open`: this
 * turn may well be the one that pushes a branch, and a token that expired
 * while the tab was open fails as an authentication error in the middle of
 * somebody's work.
 */
export async function prompt(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  const body = await readJson(req);
  const text = str(body.prompt, 100_000);
  const images = readImages(body.images);
  if (!text.trim() && !images.length) throw new HttpError(422, "empty_prompt", "Say something.");
  if (!track.conversationId) throw new HttpError(409, "not_open", "This track has no conversation yet.");

  // Name the sender only once there is somebody to distinguish them from. A
  // solo track prefixed with your own login reads as the app talking to
  // itself, and it would put a label in every transcript in the fleet to serve
  // the few that are shared.
  const shared = ctx.db.membersOf(track.id).length > 0;
  const outgoing = shared ? withAuthor(user.login, text) : text;

  await prepareMachine(ctx, project, fountain);
  try {
    await fountain.prompt(track.conversationId, outgoing, images);
  } catch (err) {
    throw asHttpError(err, "send that");
  }
  publish(project.id, { event: "turn", data: { trackId: track.id, status: "running" } });
  return json({ data: { ok: true } });
}

/**
 * `POST /api/tracks/:id/read` — this person has seen it up to now.
 *
 * Sent by the browser when a track is open and settled, rather than inferred
 * from the `GET`: opening a track to glance at the branch name is not reading
 * three turns of output, and a read mark set by the fetch would clear the dot
 * before anybody looked.
 */
export async function markRead(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  ctx.db.markRead(track.id, user.id);
  publish(project.id, { event: "tracks", data: { projectId: project.id } });
  return json({ data: { ok: true } });
}

/**
 * What the browser may attach to a prompt.
 *
 * Fountain takes `{data, media_type}` with the data base64. The cap is on the
 * decoded size and on the count, because the browser is not the only thing
 * that can post here and an unbounded list of megabyte data URLs is a way to
 * fill the machine's memory rather than a feature.
 */
function readImages(raw: unknown): { data: string; media_type: string }[] {
  if (!Array.isArray(raw)) return [];
  const ok = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);
  const out: { data: string; media_type: string }[] = [];
  for (const item of raw.slice(0, 6)) {
    if (!item || typeof item !== "object") continue;
    const { data, media_type } = item as { data?: unknown; media_type?: unknown };
    if (typeof data !== "string" || typeof media_type !== "string" || !ok.has(media_type)) continue;
    // base64 is four characters per three bytes.
    if (data.length > (8 * 1024 * 1024 * 4) / 3) throw new HttpError(413, "image_too_large", "That image is larger than 8 MB.");
    out.push({ data, media_type });
  }
  return out;
}

/**
 * `POST /api/tracks/:id/presence` — I am here, and possibly typing.
 *
 * One route for both because they are one heartbeat: the browser is already
 * saying "still watching" on a timer, and `typing` rides along rather than
 * opening a second channel that could disagree with the first about whether
 * somebody is still in the room.
 *
 * `leaving` is the polite half. A lease would expire on its own in
 * forty-five seconds, but somebody closing a track is the one moment we
 * actually know, and a ghost in the corner of a colleague's screen for most of
 * a minute is exactly the small wrongness that makes presence feel broken.
 */
export async function presence(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  const body = await readJson(req);

  // Who may be told. The owner always, everybody in the whole project, and
  // this track's own members — and nobody else on the project's channel,
  // because an event naming a track is an event that says the track exists.
  // The middle group is the one that is easy to forget and shows up as a
  // project member watching a track whose other readers cannot see them.
  const audience = new Set<string>([
    project.userId,
    ...ctx.db.projectMembersOf(project.id).map((m) => m.id),
    ...ctx.db.membersOf(track.id).map((m) => m.id),
  ]);

  if (body.leaving === true) {
    leave(track.id, user.id, project.id, audience);
    return json({ data: [] });
  }

  const here = beat({
    trackId: track.id,
    projectId: project.id,
    userId: user.id,
    login: user.login,
    name: user.name,
    avatarUrl: user.avatarUrl,
    typing: body.typing === true,
    audience,
  });
  return json({ data: here });
}

/** `POST /api/tracks/:id/interrupt` */
export async function interrupt(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  if (!track.conversationId) throw new HttpError(409, "not_open", "This track has no conversation yet.");
  try {
    await fountain.interrupt(track.conversationId);
  } catch (err) {
    throw asHttpError(err, "stop that turn");
  }
  return json({ data: { ok: true } });
}

/**
 * `GET /api/tracks/:id/events` — the transcript so far, both halves of it.
 *
 * The prompts and the output live in two different places on Fountain and are
 * joined on `turn_id`. Joining them here rather than in the browser is not
 * tidiness: it is one round trip instead of two on the call that gates the
 * first paint of a track.
 */
export async function events(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  if (!track.conversationId) return json({ data: { turns: [], events: [] } });
  try {
    const [turns, log] = await Promise.all([
      // A conversation too new to have turns is ordinary, not an error.
      fountain.turns(track.conversationId).catch(() => []),
      fountain.events(track.conversationId),
    ]);
    const page: TranscriptPage = {
      turns: turns.map((t) => ({
        id: t.id,
        prompt: typeof t.prompt === "string" ? t.prompt : null,
        origin: typeof t.origin === "string" ? t.origin : null,
        status: typeof t.status === "string" ? t.status : null,
        insertedAt: typeof t.inserted_at === "string" ? t.inserted_at : null,
      })),
      events: log,
    };
    return json({ data: page });
  } catch (err) {
    throw asHttpError(err, "read this track");
  }
}

/**
 * `GET /api/tracks/:id/stream` — Fountain's stream, forwarded.
 *
 * The one place switchyard hands a Fountain response body straight through.
 * Reading it here to re-emit would mean buffering a stream whose entire
 * purpose is not being buffered; the authorization has already happened in
 * `trackOf`, and what comes back is one conversation's events and nothing
 * else.
 */
export async function stream(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  if (!track.conversationId) throw new HttpError(409, "not_open", "This track has no conversation yet.");
  let res: Response;
  try {
    res = await fountain.stream(track.conversationId, req.signal);
  } catch (err) {
    throw asHttpError(err, "watch this track");
  }
  return new Response(res.body, {
    status: res.status,
    headers: {
      "content-type": res.headers.get("content-type") ?? "text/event-stream",
      "cache-control": "no-cache, no-transform",
      "x-accel-buffering": "no",
    },
  });
}

/**
 * `PATCH /api/tracks/:id` — rename the label, and only the label.
 *
 * A track is named before anybody knows what it is — after a pull request, a
 * branch, or the yard's own list — so the name it opened with is frequently
 * the wrong one by the end. The slug, the branch and the worktree deliberately
 * do not follow it: those were cut on a real machine when the track opened,
 * and a directory somebody is working in is not something a rename box should
 * move under them. The name in the rail is a label; this changes the label.
 */
export async function rename(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project, role } = trackOf(ctx, user, trackId);
  // Somebody invited to help on one branch is not somebody who relabels it in
  // everybody else's rail — but whoever cut it named it in the first place.
  requireOwnerOrCutter(role, user, track, "rename a track");
  const body = await readJson(req);
  const title = str(body.title, 200).trim();
  if (!title) throw new HttpError(422, "no_title", "A track needs a name.");
  ctx.db.renameTrack(track.id, title);
  publish(project.id, { event: "tracks", data: { projectId: project.id } });
  return json({ data: { ok: true } });
}

/**
 * `DELETE /api/tracks/:id` — close the track and take the worktree away.
 *
 * The branch is deliberately left alone. It may be pushed, it may be an open
 * pull request, and "close this tab" is not a gesture that should delete
 * somebody's work. The worktree goes because it is a directory on a shared
 * disk that nothing else will ever use.
 *
 * `git worktree remove` rather than `rm -rf`: the clone keeps an administrative
 * record of every worktree it cut, and a directory deleted from underneath it
 * leaves that record behind — after which the *next* track with the same name
 * is refused for a reason nobody can see.
 */
export async function close(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project, role } = trackOf(ctx, user, trackId);
  // Closing ends the track for everybody in it and takes the worktree away.
  // That is the owner's call, or the caller's own if they are the one who cut
  // it; for anybody else the way out is to leave.
  requireOwnerOrCutter(role, user, track, "close a track");
  const fountain = requireFountain(ctx);
  const force = new URL(req.url).searchParams.get("force") === "1";

  if (track.conversationId) {
    // A project with no repository still has a directory per track — the
    // opening turn made one with `mkdir -p` — so the close turn is sent either
    // way and `closeTrackPrompt` decides between `git worktree remove` and
    // `rm -rf`. Skipping it here would leak the directory of every track on
    // every bare machine.
    //
    // Best effort, and on purpose. A machine that is asleep, at capacity or
    // gone must not stop somebody closing a track — the row is switchyard's
    // and the worktree is tidied on the next survey if this turn never lands.
    const repoPath = project.repoFullName ? mountPathFor(project.repoFullName) : null;
    await fountain
      .prompt(track.conversationId, closeTrackPrompt({ slug: track.slug, repoPath, force }))
      .catch(() => undefined);
    await fountain.terminate(track.conversationId).catch(() => undefined);
  }

  ctx.db.closeTrack(track.id);
  publish(project.id, { event: "tracks", data: { projectId: project.id } });
  return json({ data: { ok: true } });
}

// ── reading a track's directory ────────────────────────────────────────

/** `GET /api/tracks/:id/files?path=` — free, and it does not wake a parked box. */
export async function files(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  const machine = await machineOf(fountain, project);
  if (!machine) throw new HttpError(409, "no_machine", "This project has no machine yet.");
  const path = confine(track.workdir, new URL(req.url).searchParams.get("path"));
  try {
    return json({ data: await fountain.listing(machine.sandboxId, path) });
  } catch (err) {
    throw asHttpError(err, "read that directory");
  }
}

/** `GET /api/tracks/:id/file?path=` */
export async function file(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  const machine = await machineOf(fountain, project);
  if (!machine) throw new HttpError(409, "no_machine", "This project has no machine yet.");
  const path = confine(track.workdir, new URL(req.url).searchParams.get("path"));
  try {
    return json({ data: await fountain.file(machine.sandboxId, path) });
  } catch (err) {
    throw asHttpError(err, "read that file");
  }
}

/** `GET /api/tracks/:id/diff` — `git diff` in this track's worktree, parsed. */
export async function diff(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { track, project } = trackOf(ctx, user, trackId);
  const fountain = requireFountain(ctx);
  const machine = await machineOf(fountain, project);
  if (!machine) throw new HttpError(409, "no_machine", "This project has no machine yet.");
  try {
    const raw = await fountain.diff(machine.sandboxId, track.workdir);
    return json({
      data: {
        path: raw.path,
        repoRoot: raw.repo_root,
        diff: raw.diff,
        truncated: raw.truncated,
        files: summarizeDiff(raw.diff),
      },
    });
  } catch (err) {
    throw asHttpError(err, "read the changes");
  }
}

/**
 * A unified diff, counted per file.
 *
 * Done here rather than in the browser because the panel wants the file list
 * before it renders anything, and re-deriving it on every keystroke in a
 * filter box is work that has one right answer and no reason to be repeated.
 */
export function summarizeDiff(diff: string): { path: string; added: number; removed: number; status: "added" | "modified" | "deleted" | "renamed" }[] {
  const out: { path: string; added: number; removed: number; status: "added" | "modified" | "deleted" | "renamed" }[] = [];
  let current: (typeof out)[number] | null = null;
  for (const line of diff.split("\n")) {
    const header = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
    if (header) {
      current = { path: header[2]!, added: 0, removed: 0, status: header[1] === header[2] ? "modified" : "renamed" };
      out.push(current);
      continue;
    }
    if (!current) continue;
    if (line.startsWith("new file")) current.status = "added";
    else if (line.startsWith("deleted file")) current.status = "deleted";
    // `+++`/`---` are the file headers, not content, and counting them would
    // put a phantom line on every changed file.
    else if (line.startsWith("+") && !line.startsWith("+++")) current.added++;
    else if (line.startsWith("-") && !line.startsWith("---")) current.removed++;
  }
  return out;
}

// ── the pieces the routes above share ──────────────────────────────────

/**
 * The project's machine, read live from its conversations. Nothing is stored.
 *
 * The list is enough for everything except the terminal: it carries
 * `sandbox_id`, which is all the file, diff and listing routes need. It does
 * *not* carry the sandbox object — `GET /api/conversations` serves
 * `"sandbox": null` — so anything wanting `sprite_name` has to ask
 * `spriteFor` and pay for the extra call, rather than reading a field that is
 * reliably absent.
 */
export async function machineOf(fountain: Fountain, project: ProjectRow): Promise<{ sandboxId: string } | null> {
  let all: ConversationSummary[];
  try {
    all = await fountain.listConversations(project.agentId);
  } catch (err) {
    throw asHttpError(err, "find this project's machine");
  }
  const newest = all
    .filter((c) => c.sandbox_id && ["pending", "idle", "running"].includes(c.status))
    .sort((a, b) => b.inserted_at.localeCompare(a.inserted_at))[0];
  return newest ? { sandboxId: newest.sandbox_id! } : null;
}

/**
 * The sprite behind a sandbox, or null if it is not on Sprites at all.
 *
 * One call, made only by the two panels that need a shell. A sandbox on
 * another provider is a real answer rather than a failure — the terminal says
 * so — which is why this returns null instead of throwing.
 */
export async function spriteFor(fountain: Fountain, sandboxId: string): Promise<string | null> {
  try {
    const sandbox = await fountain.sandbox(sandboxId);
    return sandbox.sprite_name ?? null;
  } catch {
    return null;
  }
}

async function conversationsOf(ctx: AppContext, project: ProjectRow): Promise<Map<string, ConversationSummary>> {
  const out = new Map<string, ConversationSummary>();
  if (!ctx.fountain) return out;
  const all = await ctx.fountain.listConversations(project.agentId).catch(() => [] as ConversationSummary[]);
  for (const c of all) out.set(c.id, c);
  return out;
}

/**
 * A path, pinned inside the track's own worktree.
 *
 * The Files panel belongs to a track, and a track is one directory. The
 * browser says where it wants to look; this decides. Without it the panel is a
 * way to read every other track's work — and, since `GET /api/sandboxes/:id/file`
 * will happily serve `/home/sprite/.ssh`, rather more than that.
 */
export function confine(root: string, requested: string | null): string {
  if (!requested) return root;
  const abs = requested.startsWith("/") ? requested : `${root}/${requested}`;
  const parts: string[] = [];
  for (const part of abs.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  const normalized = `/${parts.join("/")}`;
  return normalized === root || normalized.startsWith(`${root}/`) ? normalized : root;
}

function readOrigin(body: Record<string, unknown>, project: ProjectRow): TrackOrigin {
  const raw = (body.origin ?? {}) as { kind?: string; base?: string; number?: number; title?: string };
  const kind = ["branch", "pr", "issue", "blank"].includes(raw.kind ?? "") ? (raw.kind as TrackOrigin["kind"]) : "blank";
  if (kind === "blank") return { kind: "blank", base: project.defaultBranch };
  return {
    kind,
    base: str(raw.base, 200).trim() || project.defaultBranch,
    number: Number(raw.number) || null,
    title: str(raw.title, 200).trim() || null,
  };
}

/**
 * What a track is called when nobody said.
 *
 * The order is deliberate: a track that came from a pull request, an issue or
 * a branch already has the best name available — the one the work is called
 * everywhere else — and inventing a prettier one would break the join between
 * the sidebar and GitHub. Only a track started from nothing gets a yard name,
 * because only that one has no name to inherit.
 */
function defaultTitle(origin: TrackOrigin, taken: string[]): string {
  if (origin.kind === "pr" && origin.number) return origin.title || `PR #${origin.number}`;
  if (origin.kind === "issue" && origin.number) return origin.title || `Issue #${origin.number}`;
  if (origin.kind === "branch" && origin.base) return origin.base;
  return nameTrack(taken);
}

function originUrl(project: ProjectRow, origin: TrackOrigin): string | null {
  if (!project.repoFullName || !origin.number) return null;
  const kind = origin.kind === "pr" ? "pull" : "issues";
  return `https://github.com/${project.repoFullName}/${kind}/${origin.number}`;
}

/**
 * A slug nobody else is using.
 *
 * A slug is a directory on a real machine, so a clash is not a naming
 * inconvenience — it is two tracks writing to one worktree. Suffixing is
 * better than refusing: somebody opening a second track from the same pull
 * request means it, and being told "that name is taken" about a name they
 * never chose is a dead end.
 */
function freeSlug(ctx: AppContext, projectId: string, from: string): string {
  const base = slugify(from);
  if (!ctx.db.slugTaken(projectId, base)) return base;
  for (let n = 2; n < 100; n++) {
    const candidate = `${base}-${n}`;
    if (!ctx.db.slugTaken(projectId, candidate)) return candidate;
  }
  return `${base}-${Date.now().toString(36)}`;
}

export function toTrack(
  row: TrackRow,
  project: ProjectRow,
  live: ConversationSummary | null,
  people: Person[] = [],
  role: "owner" | "member" = "owner",
  lastRead: string | null = null,
): Track {
  const origin: TrackOriginInfo = originOf(row);
  return {
    id: row.id,
    projectId: row.projectId,
    conversationId: row.conversationId,
    slug: row.slug,
    title: row.title,
    branch: row.branch,
    workdir: row.workdir,
    origin,
    status: statusOf(row, live),
    // The revision is in the channel id the conversation already carries, so
    // "is this track behind?" is a comparison rather than a stored flag.
    stale: row.rev < project.rev,
    openedAt: row.openedAt,
    lastActiveAt: live?.last_active_at ?? null,
    turnCount: live?.turn_count ?? 0,
    createdAt: row.createdAt,
    createdByLogin: row.createdByLogin,
    people,
    role,
    // A track nobody has opened is unread the moment the machine says
    // anything; one whose last activity predates your last look is not. The
    // comparison is against `last_active_at` rather than a turn count so a
    // streamed reply marks it unread as it arrives.
    unread: unreadOf(live?.last_active_at ?? null, lastRead),
  };
}

function unreadOf(lastActiveAt: string | null, lastRead: string | null): boolean {
  if (!lastActiveAt) return false;
  if (!lastRead) return true;
  return Date.parse(lastActiveAt) > Date.parse(lastRead);
}

function statusOf(row: TrackRow, live: ConversationSummary | null): Track["status"] {
  if (row.closedAt) return "closed";
  if (live?.status === "running") return "running";
  if (live?.status === "failed") return "failed";
  if (!row.openedAt) return "opening";
  return "ready";
}
