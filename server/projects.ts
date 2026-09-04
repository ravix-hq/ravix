/**
 * Projects, which are machines.
 *
 * Creating one is four Fountain calls in a fixed order and the order is the
 * whole design. Sandbox identity is `(user, agent, environment, vault)` *by
 * id*, so the environment and the vault must exist before the agent, because
 * the agent is created already pointing at them. An agent updated afterwards
 * to point at them would be an agent whose identity changed between its
 * creation and its first machine — and a changed identity is a lost disk.
 *
 * After that, nothing here ever replaces one of those three records. Every
 * setting the project panel offers is a mutation in place. That is the same
 * decision paddock made and for the same reason: the machine is the thing
 * people care about, and no configuration change should be able to take it.
 *
 * The credential is the part switchyard does differently, because it has a
 * GitHub App and paddock deliberately does not. A private repository is cloned
 * with an **installation token** — scoped to the repositories that person
 * chose, expiring in an hour — written into the project's *vault* under
 * `GITHUB_TOKEN`. Fountain's egress broker keeps a two-entry catalog of
 * exactly `GITHUB_TOKEN` and `GH_TOKEN` and attaches git's `x-access-token`
 * basic auth in flight, so the machine holds a placeholder and never the token
 * itself. That is worth the whole GitHub App on its own: the alternative is a
 * personal token, scoped to everything you can reach, sitting in an env var
 * that any agent turn can print.
 */
import { randomUUID } from "node:crypto";
import type { Project, ProjectSettings, MachineState } from "../shared/api";
import { mountPathFor } from "../shared/ids";
import { systemPrompt } from "../shared/spec";
import type { AppContext } from "./context";
import { authenticate, projectOf, requireFountain, requireGitHub, userToken } from "./context";
import type { ProjectRow, UserRow } from "./db";
import type { Fountain } from "./fountain";
import { FountainHttpError, asHttpError } from "./fountain";
import { asHttpError as asGitHubError } from "./github";
import { HttpError, json, readJson, str } from "./http";
import { publish } from "./hub";

/**
 * The credential name is load-bearing.
 *
 * Only `GITHUB_TOKEN` and `GH_TOKEN` get git's basic-auth rule from the
 * broker. A GitHub *connection* is brokered too, but under
 * `GITHUB_ACCESS_TOKEN` and as a bearer, which git over HTTPS does not use —
 * so a connection buys the agent the GitHub API and not a checkout. Renaming
 * this constant silently turns every private clone into a 403.
 */
export const CLONE_SECRET_KEY = "GITHUB_TOKEN";

const DEFAULT_RUNTIME = "claude";
/**
 * Provider-prefixed, because Fountain's are.
 *
 * `POST /api/agents` validates `model` against `^[a-z0-9_-]+/[a-z0-9._-]+$`,
 * and the catalog lists `anthropic/claude-opus-5`. A bare `claude-opus-5`
 * survived here for a while only because `pickRuntime` falls through to
 * "whatever in the catalog has opus in the name" — so the wrong constant was
 * invisible until the catalog call failed, at which point every project
 * creation would have 422'd on a field nobody was looking at.
 */
const DEFAULT_MODEL = "anthropic/claude-opus-5";

/**
 * How the caller reaches a project, or null when they do not.
 *
 * Three sources, widest first, and the order is what makes the answer stable:
 * somebody who owns a project *and* somehow holds rows in it is still its
 * owner, and somebody in the whole project who is also named on one track is
 * still in the whole project. The narrowest answer is the one that has to be
 * checked last or it wins over facts that grant more.
 *
 * One function rather than the same three-line union written out in `list`,
 * `show` and the stream's gate, which is where it was drifting.
 */
export function accessOf(ctx: AppContext, userId: string, project: ProjectRow): Project["access"] | null {
  if (project.userId === userId) return "owner";
  if (ctx.db.isProjectMember(project.id, userId)) return "project";
  if (ctx.db.memberTracks(userId).some((t) => t.projectId === project.id)) return "tracks";
  return null;
}

/** `GET /api/projects` */
export async function list(ctx: AppContext, req: Request): Promise<Response> {
  const user = await authenticate(ctx, req);
  const mine = ctx.db.projectsOf(user.id);

  // A project somebody let you into shows in the rail beside your own, whether
  // they let you into the whole thing or into one track of it — the
  // alternative is a track with no home in the sidebar. What it is marked
  // decides which controls the rail draws; the routes behind them refuse the
  // rest regardless.
  const seen = new Set(mine.map((p) => p.id));
  const guest: ProjectRow[] = [];
  const add = (project: ProjectRow | null) => {
    if (!project || project.archivedAt || seen.has(project.id)) return;
    seen.add(project.id);
    guest.push(project);
  };
  for (const project of ctx.db.memberProjects(user.id)) add(project);
  for (const track of ctx.db.memberTracks(user.id)) add(ctx.db.project(track.projectId));

  const rows = [...mine, ...guest];
  const machines = await machinesFor(ctx, rows);
  return json({
    data: rows.map((r) => {
      const owner = r.userId === user.id ? user : (ctx.db.user(r.userId) ?? user);
      return toProject(r, machines.get(r.id) ?? none(), owner, accessOf(ctx, user.id, r) ?? "tracks");
    }),
  });
}

/** `GET /api/projects/:id` */
export async function show(ctx: AppContext, req: Request, id: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const row = ctx.db.project(id);
  if (!row || row.archivedAt) throw new HttpError(404, "not_found", "No such project.");

  // A member needs the project's name, repository and model to render the
  // header and the composer above their track. They are given exactly that —
  // the same shape everyone gets, marked with how they got here — and every
  // route that would *change* any of it goes through `projectOf` and refuses
  // them.
  const access = accessOf(ctx, user.id, row);
  if (!access) throw new HttpError(404, "not_found", "No such project.");
  const ownerRow = access === "owner" ? user : (ctx.db.user(row.userId) ?? user);
  const machines = await machinesFor(ctx, [row]);
  return json({ data: toProject(row, machines.get(row.id) ?? none(), ownerRow, access) });
}

/**
 * `POST /api/projects` — a repository becomes a machine.
 *
 * The repository is read as the *installation* rather than as the person, so
 * a private repo resolves and its default branch is real. Reading it also
 * proves the installation actually grants it, which is the check that stops
 * somebody pointing a project at a repository they merely know the name of.
 */
export async function create(ctx: AppContext, req: Request): Promise<Response> {
  const user = await authenticate(ctx, req);
  const fountain = requireFountain(ctx);
  const body = await readJson(req);

  const repoFullName = str(body.repo, 200).trim() || null;
  const installationId = Number(body.installationId) || null;
  let name = str(body.name, 120).trim();
  let defaultBranch: string | null = null;
  let isPrivate = false;

  if (repoFullName) {
    if (!installationId) throw new HttpError(422, "no_installation", "Pick a repository from an account switchyard is installed on.");
    const gh = requireGitHub(ctx);
    // Proves the installation grants it, and gets the branch we will cut from.
    let repo;
    try {
      const mine = await gh.repositories(await userToken(ctx, user), installationId);
      repo = mine.find((r) => r.fullName.toLowerCase() === repoFullName.toLowerCase());
    } catch (err) {
      throw asGitHubError(err, "read that repository");
    }
    if (!repo) throw new HttpError(404, "repo_not_found", "That repository is not one this installation grants.");
    defaultBranch = repo.defaultBranch;
    isPrivate = repo.private;
    if (!name) name = repo.name;
  }
  if (!name) throw new HttpError(422, "no_name", "Give the project a name.");

  const projectId = randomUUID();
  const label = `Switchyard · ${name}`;
  const repoPath = repoFullName ? mountPathFor(repoFullName) : null;

  // ── the three records, in the only order that works ──────────────────
  let environmentId: string | null = null;
  let vaultId: string | null = null;
  let agentId: string | null = null;
  try {
    const environment = await fountain.createEnvironment({
      name: label,
      repositories: repoFullName
        ? [
            {
              url: `https://github.com/${repoFullName}.git`,
              mount_path: repoPath!,
              // Named on the repository whether or not it is private. A public
              // repo with a token attached still clones; a private one without
              // it fails at build time with an error a person cannot act on.
              secret_key: CLONE_SECRET_KEY,
            },
          ]
        : [],
      packages: {},
      setup_script: "",
    });
    environmentId = environment.id;

    // Created up front even though nothing needs it yet, precisely because
    // attaching one later would change the identity and cost the disk.
    const vault = await fountain.createVault({ name: label }).catch((err) => {
      if (err instanceof FountainHttpError && [403, 404, 501].includes(err.status)) return null;
      throw err;
    });
    vaultId = vault?.id ?? null;

    // The clone token, before the first machine is ever built. It expires in
    // an hour and is re-minted on every path that wakes the box — see
    // `refreshCloneToken` — but it has to be there for the *first* build too.
    if (vaultId && installationId) await refreshCloneToken(ctx, { vaultId, installationId, fountain });

    const catalog = await fountain.catalog().catch(() => null);
    const choice = pickRuntime(catalog);
    const agent = await fountain.createAgent({
      name: label,
      model: choice.model,
      runtime: choice.runtime,
      // The identity's own default, so every track on it gets the same home
      // without having to say so on each conversation.
      sandbox_mode: "persistent",
      description: repoFullName ? `The agent working on ${repoFullName}.` : "The agent on this switchyard project.",
      system: systemPrompt({ project: name, repoPath, defaultBranch }),
      environment_id: environmentId,
      ...(vaultId ? { vault_id: vaultId } : {}),
      metadata: { switchyard: { project: projectId } },
    });
    agentId = agent.id;
  } catch (err) {
    // A half-made project is three orphaned Fountain records and a row that
    // points at a machine nobody can build. Unwind what went in, in reverse,
    // and report the original failure rather than the cleanup's.
    await unwind(fountain, { agentId, vaultId, environmentId });
    throw asHttpError(err, "build this project");
  }

  const row = ctx.db.createProject({
    id: projectId,
    userId: user.id,
    name,
    repoFullName,
    repoPrivate: isPrivate ? 1 : 0,
    defaultBranch,
    installationId,
    agentId: agentId!,
    environmentId: environmentId!,
    vaultId,
    runtime: DEFAULT_RUNTIME,
    model: DEFAULT_MODEL,
    instructions: "",
  });

  return json({ data: toProject(row, none(), user) }, 201);
}

/**
 * The clone token, re-minted.
 *
 * An installation token lives for an hour, and Fountain hands the vault to a
 * sandbox when a *session* starts — so a project a person comes back to the
 * next morning has a dead token in it, and the symptom is `git push` failing
 * with "Authentication failed" in the middle of a turn. Every path that is
 * about to make the machine talk to GitHub calls this first. GitHub's own
 * token cache makes the repeat calls nearly free.
 */
export async function refreshCloneToken(
  ctx: AppContext,
  input: { vaultId: string; installationId: number; fountain: Fountain },
): Promise<void> {
  const gh = ctx.github;
  if (!gh) return;
  try {
    const token = await gh.mintCloneToken(input.installationId);
    await input.fountain.putSecret("vaults", input.vaultId, CLONE_SECRET_KEY, token);
  } catch (err) {
    // Not fatal on its own: a public repository clones without it, and a
    // private one fails later with Fountain's own message. Logged rather than
    // thrown so a GitHub blip does not stop somebody opening a track.
    console.error("switchyard: could not refresh the clone token:", err instanceof Error ? err.message : err);
  }
}

/** Everything a project needs before its machine is woken. */
export async function prepareMachine(ctx: AppContext, project: ProjectRow, fountain: Fountain): Promise<void> {
  if (project.vaultId && project.installationId) {
    await refreshCloneToken(ctx, { vaultId: project.vaultId, installationId: project.installationId, fountain });
  }
}

/** `GET /api/projects/:id/settings` */
export async function settings(ctx: AppContext, req: Request, id: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const project = projectOf(ctx, user, id);
  const fountain = requireFountain(ctx);
  try {
    const [env, envKeys, vaultKeys] = await Promise.all([
      fountain.getEnvironment(project.environmentId),
      fountain.secretKeys("environments", project.environmentId).catch(() => []),
      project.vaultId ? fountain.secretKeys("vaults", project.vaultId).catch(() => []) : Promise.resolve([]),
    ]);
    const out: ProjectSettings = {
      name: project.name,
      setupScript: env.setup_script ?? "",
      packages: env.packages ?? {},
      envKeys: envKeys.map((k) => k.key),
      // The clone token is switchyard's own plumbing, not one of the person's
      // secrets. Listing it invites somebody to delete it and then wonder why
      // their private repository stopped cloning.
      vaultKeys: vaultKeys.map((k) => k.key).filter((k) => k !== CLONE_SECRET_KEY),
      model: project.model,
      instructions: project.instructions,
    };
    return json({ data: out });
  } catch (err) {
    throw asHttpError(err, "read this project's settings");
  }
}

/**
 * `PUT /api/projects/:id/settings` — every field a mutation in place.
 *
 * The revision is bumped whenever something Fountain injects at *session*
 * start changes, which is not the same set as "things that changed". A setup
 * script is applied when the disk is built; a secret reaches the next track
 * and no earlier. Tracks already open carry the old revision in their channel
 * id and are badged accordingly, which is true and costs nothing to compute.
 */
export async function updateSettings(ctx: AppContext, req: Request, id: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const project = projectOf(ctx, user, id);
  const fountain = requireFountain(ctx);
  const body = await readJson(req);

  let bumps = false;
  try {
    if (typeof body.name === "string" && body.name.trim()) ctx.db.renameProject(project.id, str(body.name, 120).trim());

    if (typeof body.setupScript === "string" || body.packages !== undefined) {
      const patch: Record<string, unknown> = {};
      if (typeof body.setupScript === "string") patch.setup_script = str(body.setupScript, 20_000);
      if (body.packages !== undefined) patch.packages = normalizePackages(body.packages);
      await fountain.updateEnvironment(project.environmentId, patch);
    }

    if (typeof body.instructions === "string") {
      const instructions = str(body.instructions, 20_000);
      ctx.db.setInstructions(project.id, instructions);
      await fountain.updateAgent(project.agentId, {
        system: composeSystem({ ...project, instructions }),
      });
      bumps = true;
    }

    if (typeof body.model === "string" && body.model.trim()) {
      ctx.db.setModel(project.id, str(body.model, 80).trim());
      await fountain.updateAgent(project.agentId, { model: str(body.model, 80).trim() });
      bumps = true;
    }

    if (body.secret && typeof body.secret === "object") {
      const s = body.secret as { store?: string; key?: string; value?: string };
      const store = s.store === "vault" ? "vaults" : "environments";
      const key = str(s.key, 200).trim();
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new HttpError(422, "bad_key", "A secret name is letters, digits and underscores.");
      if (key === CLONE_SECRET_KEY) throw new HttpError(422, "reserved_key", `${CLONE_SECRET_KEY} is switchyard's own and is re-minted from GitHub.`);
      const target = store === "vaults" ? project.vaultId : project.environmentId;
      if (!target) throw new HttpError(409, "no_vault", "This project has no vault, so it can only hold environment secrets.");
      if (typeof s.value === "string" && s.value.length) await fountain.putSecret(store, target, key, s.value);
      else await fountain.deleteSecret(store, target, key);
      bumps = true;
    }
  } catch (err) {
    if (err instanceof HttpError) throw err;
    throw asHttpError(err, "save these settings");
  }

  const rev = bumps ? ctx.db.bumpRev(project.id) : project.rev;
  publish(project.id, { event: "settings", data: { rev } });
  return json({ data: { rev } });
}

/**
 * The agent's system prompt: the contract, plus whatever the person added.
 *
 * The order is not negotiable. The worktree rule goes first and the person's
 * instructions go after, because the rule is what keeps tracks from writing
 * over each other and an instruction file that opened with "ignore previous
 * instructions" should not be able to undo it by being first.
 */
export function composeSystem(project: ProjectRow): string {
  const base = systemPrompt({
    project: project.name,
    repoPath: project.repoFullName ? mountPathFor(project.repoFullName) : null,
    defaultBranch: project.defaultBranch,
  });
  const extra = project.instructions.trim();
  return extra ? `${base}\n\n## This project's own instructions\n\n${extra}` : base;
}

/**
 * `POST /api/projects/:id/rebuild` — a new machine, the same settings.
 *
 * Retiring the *agent* is what changes the identity, and it leaves the
 * environment and the vault — and therefore every repository, package and
 * secret — exactly where they were. Every track is closed with it, because a
 * track is a worktree on a disk that is about to stop existing and a sidebar
 * full of rows pointing at nothing is worse than an empty one.
 */
export async function rebuild(ctx: AppContext, req: Request, id: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const project = projectOf(ctx, user, id);
  const fountain = requireFountain(ctx);

  const removed: string[] = [];
  const failed: { what: string; why: string }[] = [];

  let conversations: { id: string; status: string; channel_id: string | null }[] = [];
  try {
    conversations = (await fountain.listConversations(project.agentId)) as typeof conversations;
  } catch (err) {
    throw asHttpError(err, "find this project's machine");
  }
  for (const c of conversations.filter((c) => ["pending", "idle", "running"].includes(c.status))) {
    await fountain.terminate(c.id).then(
      () => removed.push("track"),
      (err) => failed.push({ what: `track ${c.id}`, why: reason(err) }),
    );
  }

  // The one removal that has to work: without it the next launch finds the
  // same identity and the same box, and a "rebuild" that quietly did nothing
  // is worse than one that says it failed.
  try {
    await fountain.deleteAgent(project.agentId);
    removed.push("agent");
  } catch (err) {
    throw asHttpError(err, "retire this project's machine");
  }

  const catalog = await fountain.catalog().catch(() => null);
  const choice = pickRuntime(catalog);
  let agent;
  try {
    agent = await fountain.createAgent({
      name: `Switchyard · ${project.name}`,
      model: project.model || choice.model,
      runtime: project.runtime || choice.runtime,
      sandbox_mode: "persistent",
      system: composeSystem(project),
      environment_id: project.environmentId,
      ...(project.vaultId ? { vault_id: project.vaultId } : {}),
      metadata: { switchyard: { project: project.id } },
    });
  } catch (err) {
    throw asHttpError(err, "build this project a new machine");
  }

  // The agent id is the identity, so it is the one column that ever moves —
  // and when it moves, every track on the old disk is gone.
  ctx.db.rebindAgent(project.id, agent.id);
  for (const t of ctx.db.tracksOf(project.id)) ctx.db.closeTrack(t.id);
  publish(project.id, { event: "tracks", data: { projectId: project.id } });

  return json({ data: { removed, failed } });
}

/** `DELETE /api/projects/:id` — the machine, its settings and its secrets. */
export async function destroy(ctx: AppContext, req: Request, id: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const project = projectOf(ctx, user, id);
  const fountain = requireFountain(ctx);

  const conversations = await fountain.listConversations(project.agentId).catch(() => []);
  for (const c of conversations) {
    if (["pending", "idle", "running"].includes(c.status)) await fountain.terminate(c.id).catch(() => undefined);
  }
  await unwind(fountain, { agentId: project.agentId, vaultId: project.vaultId, environmentId: project.environmentId });
  ctx.db.archiveProject(project.id);
  return json({ data: { ok: true } });
}

// ── the machine, read live ─────────────────────────────────────────────

/**
 * Each project's machine, from its conversations.
 *
 * Nothing about a machine is stored: a sandbox id in a row is a claim that
 * goes stale the moment Fountain rebuilds anything, and a UI that confidently
 * shows a box that died an hour ago is worse than one that says it does not
 * know. One list call answers for every project at once.
 */
async function machinesFor(ctx: AppContext, rows: ProjectRow[]): Promise<Map<string, MachineState>> {
  const out = new Map<string, MachineState>();
  if (!rows.length || !ctx.fountain) return out;
  let all: Awaited<ReturnType<Fountain["listConversations"]>>;
  try {
    all = await ctx.fountain.listConversations();
  } catch {
    return out;
  }
  const byAgent = new Map<string, (typeof all)[number][]>();
  for (const c of all) {
    if (!c.agent_id) continue;
    const list = byAgent.get(c.agent_id) ?? [];
    list.push(c);
    byAgent.set(c.agent_id, list);
  }
  for (const row of rows) {
    const mine = (byAgent.get(row.agentId) ?? [])
      .filter((c) => c.sandbox_id)
      .sort((a, b) => b.inserted_at.localeCompare(a.inserted_at));
    const newest = mine[0];
    out.set(
      row.id,
      newest
        ? {
            sandboxId: newest.sandbox_id!,
            status: ["pending", "idle", "running"].includes(newest.status) ? "ready" : "suspended",
            // Deliberately null: the conversation list serves `"sandbox": null`,
            // so the only honest answer here is "not read". The terminal asks
            // `spriteFor` when it actually needs one.
            spriteName: null,
          }
        : none(),
    );
  }
  return out;
}

const none = (): MachineState => ({ sandboxId: null, status: "none", spriteName: null });

// ── shapes and small decisions ─────────────────────────────────────────

export function toProject(
  row: ProjectRow,
  machine: MachineState,
  owner: UserRow,
  access: Project["access"] = "owner",
): Project {
  return {
    id: row.id,
    name: row.name,
    repo: row.repoFullName,
    repoPrivate: !!row.repoPrivate,
    defaultBranch: row.defaultBranch,
    repoPath: row.repoFullName ? mountPathFor(row.repoFullName) : null,
    runtime: row.runtime,
    model: row.model,
    rev: row.rev,
    machine,
    createdAt: row.createdAt,
    ownerLogin: owner.login,
    role: access === "owner" ? "owner" : "member",
    access,
  };
}

/**
 * The runtime and model, reconciled with what this Fountain actually has.
 *
 * Not a question the app asks. A form on first run is a form between somebody
 * and the thing they came for, answered identically by everyone — and the
 * project panel says what was picked and lets it be changed afterwards, which
 * is where the decision belongs.
 */
export function pickRuntime(catalog: { runtimes?: string[]; models?: Record<string, string[]> } | null): { runtime: string; model: string } {
  const runtimes = catalog?.runtimes ?? [];
  const runtime = runtimes.includes(DEFAULT_RUNTIME) ? DEFAULT_RUNTIME : (runtimes[0] ?? DEFAULT_RUNTIME);
  const models = catalog?.models?.[runtime] ?? [];
  if (models.includes(DEFAULT_MODEL)) return { runtime, model: DEFAULT_MODEL };
  const opus = models.find((m) => m.includes("opus"));
  return { runtime, model: opus ?? models[0] ?? DEFAULT_MODEL };
}

/**
 * Packages, keyed by manager.
 *
 * Fountain rejects a flat array outright — `{"packages":["Invalid object. Got:
 * array"]}` — and silently stores a manager it does not know, which reads as
 * configured and installs nothing. So the shape is enforced here rather than
 * trusted from the browser.
 */
function normalizePackages(raw: unknown): Record<string, string[]> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const out: Record<string, string[]> = {};
  for (const [manager, list] of Object.entries(raw as Record<string, unknown>)) {
    if (!Array.isArray(list)) continue;
    const names = list.filter((n): n is string => typeof n === "string" && !!n.trim()).map((n) => n.trim().slice(0, 120));
    if (names.length) out[manager.slice(0, 40)] = [...new Set(names)];
  }
  return out;
}

/** Take back what went in, in reverse, ignoring what will not go. */
async function unwind(
  fountain: Fountain,
  ids: { agentId: string | null; vaultId: string | null; environmentId: string | null },
): Promise<void> {
  if (ids.agentId) await fountain.deleteAgent(ids.agentId).catch(() => undefined);
  if (ids.vaultId) await fountain.deleteVault(ids.vaultId).catch(() => undefined);
  if (ids.environmentId) await fountain.deleteEnvironment(ids.environmentId).catch(() => undefined);
}

function reason(err: unknown): string {
  if (err instanceof FountainHttpError) return err.message;
  return err instanceof Error ? err.message : "unknown";
}
