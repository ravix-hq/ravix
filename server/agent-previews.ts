import type { AppContext } from "./context";
import { trackAccess } from "./context";
import type { PromptRow } from "./db";
import { randomToken, sha256 } from "./crypto";
import { HttpError, json, readJson } from "./http";
import { previews, parsePreviewConfig } from "./previews";
import { machineOf, spriteFor } from "./tracks";
import { shq } from "./sprites";
import { STATE_DIR } from "../shared/ids";
import { AGENT_PREVIEW_START, AGENT_PREVIEW_END } from "../shared/previews";

/** The credential stays outside the checkout and transcript. The helper can
 * only operate its track's preview, never project settings or browser tickets. */
export function agentPreviewScript(url: string, token: string): string {
  return `#!/bin/sh
set -eu
case "\${1:-status}" in
  configure) [ "$#" -eq 2 ] || { echo 'Usage: preview configure <config JSON or null>' >&2; exit 2; }; body='{ "action":"configure", "config":'"$2"'}' ;;
  status|start|restart|stop|logs) body='{ "action":"'"\${1:-status}"'" }' ;;
  *) echo 'Commands: configure <JSON>, status, start, restart, stop, logs' >&2; exit 2 ;;
esac
exec curl --fail-with-body --silent --show-error --max-time 90 \\
  -H ${shq(`Authorization: Bearer ${token}`)} -H 'Content-Type: application/json' \\
  --data "$body" ${shq(url)}
`;
}

export async function prepareAgentPreview(ctx: AppContext, prompt: Omit<PromptRow, "payload">): Promise<string> {
  if (previews(ctx).unavailable()) return "";
  const track = ctx.db.track(prompt.trackId)!;
  const project = ctx.db.project(track.projectId)!;
  let hash: string | undefined;
  try {
    const machine = await machineOf(ctx.fountain!, project);
    const sprite = machine && await spriteFor(ctx.fountain!, machine.sandboxId);
    if (!machine || !sprite) throw new Error("No Sprite");
    const token = randomToken(); hash = await sha256(token);
    ctx.db.previews.grantAgent({ hash, trackId: track.id, userId: prompt.userId, conversationId: track.conversationId!,
      promptId: prompt.id, sandboxId: machine.sandboxId, sprite, expires: Date.now() + 2 * 60 * 60_000 });
    const path = `${STATE_DIR}/previews/${track.id}.sh`;
    const script = agentPreviewScript(`${ctx.config.publicUrl}/api/tracks/${encodeURIComponent(track.id)}/preview/agent`, token);
    const result = await ctx.sprites!.exec(sprite, ["sh", "-lc", `umask 077; mkdir -p ${shq(`${STATE_DIR}/previews`)} && printf %s ${shq(script)} > ${shq(path + ".tmp")} && mv ${shq(path + ".tmp")} ${shq(path)}`], 15);
    if (result.code || !ctx.db.previews.agentGrant(hash)) throw new Error("Helper unavailable");
    return [
      AGENT_PREVIEW_START,
      `You can configure this track's live preview with: sh ${shq(path)} <command>.`,
      `Commands: configure '<config JSON>', start, status, logs, restart, stop. configure null restores the project default.`,
      `Config example: ${JSON.stringify({ directory: "apps/example", command: 'npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort', readinessPath: "/" })}`,
      "When asked to set up a live preview, inspect this track's app and dependencies, choose the correct relative directory and startup command, then configure and start it. Poll status until Ready; use logs to fix failures. Do not claim readiness before the server reports it.",
      `The app must honor $PORT, refuse port fallback, and allow hosts under .${ctx.config.previews!.domain}. Keep HMR on the browser's current host/port. Scope other ports and writable data to this track.`,
      "Use this helper for managed previews; do not launch a detached dev server or change project defaults. The helper contains a temporary credential: execute it, but do not read, print, copy, or commit it. It expires after two hours and is renewed on the next user turn.",
      `When Ready, direct the user to Open preview on their track: ${ctx.config.publicUrl}/p/${project.id}/t/${track.id}. Browser sign-in stays required.`,
      AGENT_PREVIEW_END,
    ].join("\n");
  } catch {
    if (hash && ctx.db.previews.agentGrant(hash)) ctx.db.previews.revokeAgent(track.id);
    // Optional preview plumbing must never strand an ordinary saved prompt.
    return `${AGENT_PREVIEW_START}\nThe preview helper could not be prepared this turn. Continue the requested work; use the track's preview controls if needed.\n${AGENT_PREVIEW_END}`;
  }
}

export async function agentPreviewRoute(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const token = /^Bearer ([A-Za-z0-9_-]{20,})$/.exec(req.headers.get("authorization") ?? "")?.[1];
  const grant = token && ctx.db.previews.agentGrant(await sha256(token));
  if (!grant || grant.trackId !== trackId) throw new HttpError(401, "preview_agent_auth", "Preview helper expired. Send another message to renew it.");
  const user = ctx.db.user(grant.userId);
  if (!user) throw new HttpError(401, "preview_agent_auth", "Preview access ended.");
  const { track, project } = trackAccess(ctx, user, trackId);
  const manager = previews(ctx); manager.assertOpen(trackId);
  const prompt = ctx.db.queuedPrompt(grant.promptId);
  if (track.conversationId !== grant.conversationId || !prompt || prompt.trackId !== trackId || prompt.userId !== user.id || !["sending", "sent", "unconfirmed"].includes(prompt.status)) {
    throw new HttpError(401, "preview_agent_auth", "This preview helper no longer belongs to an active delivered turn.");
  }
  const why = manager.unavailable();
  if (why) throw new HttpError(501, "preview_unavailable", why);
  const body = await readJson(req);
  const action = body?.action;
  if (!["configure", "start", "restart", "stop", "status", "logs"].includes(String(action))) throw new HttpError(422, "preview_action", "Unknown preview helper command.");
  const machine = await machineOf(ctx.fountain!, project);
  if (machine?.sandboxId !== grant.sandboxId || await spriteFor(ctx.fountain!, machine.sandboxId) !== grant.sprite) throw new HttpError(409, "preview_replaced", "The workspace changed. Send another message to renew the helper.");
  // Membership can change during provider reads. Never resurrect a revoked grant.
  if (!ctx.db.previews.agentGrant(grant.hash)) throw new HttpError(401, "preview_agent_auth", "Preview access ended.");
  trackAccess(ctx, user, trackId); manager.assertOpen(trackId);
  const latestPrompt = ctx.db.queuedPrompt(grant.promptId);
  if (ctx.db.track(trackId)?.conversationId !== grant.conversationId || !latestPrompt || !["sending", "sent", "unconfirmed"].includes(latestPrompt.status)) throw new HttpError(401, "preview_agent_auth", "This preview helper's turn has ended or changed.");
  if (action === "configure") await manager.configure(trackId, parsePreviewConfig(body.config));
  if (action === "start" || action === "restart") void manager.startService(trackId, action === "restart").catch(() => {});
  if (action === "stop") await manager.stopService(trackId);
  if (action === "logs") await manager.refreshLogs(trackId);
  return json({ data: { ...manager.info(trackId), trackUrl: `${ctx.config.publicUrl}/p/${project.id}/t/${trackId}` } }, 200, { "cache-control": "no-store" });
}
