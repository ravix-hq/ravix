import type { AppContext } from "./context";
import { trackAccess } from "./context";
import type { PromptRow } from "./db";
import { browsers, browserBody } from "./browsers";
import { randomToken, sha256 } from "./crypto";
import { HttpError, json } from "./http";
import { STATE_DIR } from "../shared/ids";
import { BROWSER_TOOLS_START, BROWSER_TOOLS_END } from "../shared/browser";
import { shq } from "./sprites";

export function agentBrowserScript(url: string, token: string) {
  return `#!/bin/sh
set -eu
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo 'Usage: browser <command JSON> [screenshot output.jpg]' >&2; exit 2; }
result=$(mktemp)
trap 'rm -f "$result"' EXIT HUP INT TERM
curl --fail-with-body --silent --show-error --max-time 300 -H ${shq(`Authorization: Bearer ${token}`)} -H 'Content-Type: application/json' --data "$1" ${shq(url)} > "$result" || { cat "$result"; exit 1; }
if [ "$#" -eq 2 ]; then
  python3 -c 'import base64,json,sys; r=json.load(open(sys.argv[1]))["data"]; image=r.pop("image"); open(sys.argv[2],"wb").write(base64.b64decode(image)); print(json.dumps(r))' "$result" "$2"
else
  cat "$result"
fi
`;
}

export async function prepareAgentBrowser(ctx: AppContext, prompt: Omit<PromptRow, "payload">): Promise<string> {
  const manager = browsers(ctx);
  if (!manager.available()) return "";
  try {
    const track = ctx.db.track(prompt.trackId)!;
    const actual = await manager.destination(track.projectId);
    const token = randomToken(), hash = await sha256(token);
    ctx.db.browsers.grant({ hash, trackId: track.id, userId: prompt.userId, promptId: prompt.id, conversationId: track.conversationId!, expires: Date.now() + 2 * 60 * 60_000, ...actual });
    const path = `${STATE_DIR}/browser-tools/${track.id}.sh`;
    const script = agentBrowserScript(`${ctx.config.publicUrl}/api/tracks/${encodeURIComponent(track.id)}/browser/agent`, token);
    const result = await ctx.sprites!.exec(actual.sprite, ["sh", "-lc", `umask 077; mkdir -p ${shq(`${STATE_DIR}/browser-tools`)} && printf %s ${shq(script)} > ${shq(path + ".tmp")} && mv ${shq(path + ".tmp")} ${shq(path)}`], 15);
    if (result.code || !ctx.db.browsers.agent(hash)) throw Error("Browser helper unavailable");
    return [BROWSER_TOOLS_START,
      `This machine has one shared Switchyard browser profile, including machine-account logins, across every track and participant. Use sh ${shq(path)} '<command JSON>' [screenshot-output.jpg] to operate it. Execute the helper; never read, print, copy, or commit it because it contains a temporary credential.`,
      'Commands: {"action":"start"}, {"action":"status"}, {"action":"acquire"}, {"action":"release"}, {"action":"open","url":"https://example.com"}. Results include tabs, controller, and revision.',
      'Acquire control before changing anything. A human can take over; on a control conflict stop sending input and wait for release. Release control when done or asking the user to interact. Do not start a separate browser or bypass this helper.',
      'Tab commands include tabId: navigate (+url), close, back, forward, reload, inspect (accessibility text), screenshot (JPEG), click (+x,y normalized 0..1), scroll (+x,y,deltaX,deltaY bounded to +/-2000), text (+text), key (+Playwright key such as Enter or ControlOrMeta+A). Include the current revision on commands that change a tab. Use screenshots and inspect to verify results.',
      'A screenshot command with a second helper argument writes the JPEG to that path and omits image bytes from printed JSON. The fixed viewport is 1280 by 800.',
      'Save a portable checkpoint with {"action":"checkpoint","label":"Before task"} while controlling the browser. Checkpoints contain cookies, localStorage, IndexedDB, per-tab sessionStorage and tab URLs; they do not undo website actions. Restoring is an owner operation in Switchyard.',
      'The shared browser card is in this track’s chat. People can open it, take control, log in, and hand it back. Logins may expire and some websites may refuse an automated browser.',
      BROWSER_TOOLS_END].join("\n");
  } catch {
    return `${BROWSER_TOOLS_START}\nThe shared browser helper could not be prepared. Continue ordinary work; do not claim browser access.\n${BROWSER_TOOLS_END}`;
  }
}

export async function agentBrowserRoute(ctx: AppContext, req: Request, trackId: string) {
  const token = /^Bearer ([A-Za-z0-9_-]{20,})$/.exec(req.headers.get("authorization") ?? "")?.[1];
  const hash = token && await sha256(token);
  const authorize = () => {
    const grant = hash && ctx.db.browsers.agent(hash), user = grant && ctx.db.user(grant.userId);
    if (!grant || !user || grant.trackId !== trackId) throw new HttpError(401, "browser_agent", "Browser helper expired. Send another message to renew it.");
    const access = trackAccess(ctx, user, trackId), prompt = ctx.db.queuedPrompt(grant.promptId);
    if (access.track.closedAt || access.track.conversationId !== grant.conversationId || !prompt || prompt.trackId !== trackId || prompt.userId !== user.id || !["sending", "sent", "unconfirmed"].includes(prompt.status)) throw new HttpError(401, "browser_agent", "This browser helper no longer belongs to a delivered turn.");
    return { ...access, grant, user };
  };
  const access = authorize(), manager = browsers(ctx);
  if (!manager.available()) throw new HttpError(501, "browser_unavailable", "Shared browser is unavailable.");
  const actual = await manager.destination(access.project.id); authorize();
  if (actual.sprite !== access.grant.sprite || actual.sandboxId !== access.grant.sandboxId) throw new HttpError(409, "browser_machine", "The machine changed. Send another message to renew the browser helper.");
  const body = await browserBody(req);
  const actor = { id: `agent:${access.grant.promptId}`, label: `Agent · ${access.track.title}`, kind: "agent" as const };
  const projectId = access.project.id;
  if (body.action === "start") return json({ data: await manager.start(projectId, authorize) });
  if (body.action === "checkpoint") return json({ data: await manager.checkpoint(projectId, String(body.label ?? ""), actor, authorize) });
  return json({ data: await manager.execute(projectId, body, actor, authorize) }, 200, { "cache-control": "no-store" });
}
