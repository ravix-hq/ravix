import type { QueuedPrompt } from "../shared/api";
import { withAuthor } from "../shared/author";
import type { AppContext } from "./context";
import { authenticate, trackAccess } from "./context";
import type { PromptRow } from "./db";
import { FountainHttpError } from "./fountain";
import { HttpError, json } from "./http";
import { prepareMachine } from "./projects";
import { publish } from "./hub";

export interface PromptPayload {
  prompt: string;
  images: { data: string; media_type: string }[];
}

export function enqueue(ctx: AppContext, trackId: string, userId: string, authorLogin: string, id: unknown, payload: PromptPayload): void {
  if (typeof id !== "string" || !/^[a-zA-Z0-9-]{16,80}$/.test(id)) {
    throw new HttpError(422, "request_id_required", "Send a unique request id with this prompt.");
  }
  const existing = ctx.db.queuedPrompt(id);
  if (existing) {
    if (existing.trackId !== trackId || existing.userId !== userId) throw new HttpError(409, "request_id_used", "Use a new request id.");
    return;
  }
  if (ctx.db.promptQueueSummaries(trackId).length >= 20) throw new HttpError(409, "queue_full", "This track already has 20 saved prompts. Cancel one or wait for it to run.");
  const encoded = JSON.stringify(payload);
  if (encoded.length > 12 * 1024 * 1024) throw new HttpError(413, "prompt_too_large", "This prompt has too many image bytes. Send fewer images.");
  ctx.db.enqueuePrompt({ id, trackId, userId, authorLogin, payload: encoded });
}

export async function listQueue(ctx: AppContext, req: Request, trackId: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { role } = trackAccess(ctx, user, trackId);
  const data: QueuedPrompt[] = ctx.db.promptQueueSummaries(trackId).map((row) => {
    return {
      id: row.id, prompt: row.prompt, imageCount: row.imageCount,
      authorLogin: row.authorLogin, createdAt: row.createdAt,
      status: row.status as QueuedPrompt["status"], error: row.error,
      canCancel: row.status !== "sending" && (role === "owner" || row.userId === user.id),
    };
  });
  return json({ data });
}

export async function cancelPrompt(ctx: AppContext, req: Request, trackId: string, id: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { role } = trackAccess(ctx, user, trackId);
  const row = ctx.db.queuedPrompt(id);
  if (!row || row.trackId !== trackId) throw new HttpError(404, "not_found", "No such queued prompt.");
  if (role !== "owner" && row.userId !== user.id) throw new HttpError(403, "not_author", "Only the sender or project owner can cancel this prompt.");
  if (row.status === "sending" || row.status === "sent") throw new HttpError(409, "already_sending", "This prompt is already being delivered. Stop the turn instead.");
  ctx.db.setPromptStatus(id, "cancelled");
  return json({ data: { ok: true } });
}

export async function retryPrompt(ctx: AppContext, req: Request, trackId: string, id: string): Promise<Response> {
  const user = await authenticate(ctx, req);
  const { role, track } = trackAccess(ctx, user, trackId);
  const row = ctx.db.queuedPrompt(id);
  if (!row || row.trackId !== trackId || track.closedAt) throw new HttpError(404, "not_found", "No such queued prompt.");
  if (role !== "owner" && row.userId !== user.id) throw new HttpError(403, "not_author", "Only the sender or project owner can resend this prompt.");
  if (!["failed", "unconfirmed"].includes(row.status)) throw new HttpError(409, "not_failed", "This prompt is not waiting for a retry.");
  ctx.db.setPromptStatus(id, "queued");
  return json({ data: { ok: true } });
}

/** One worker for this deployment's single SQLite-backed server. No browser
 * connection participates in delivery. Claim immediately before POST; after a
 * crash or ambiguous response we retain the payload but never replay it blindly.
 */
export class PromptQueue {
  private busy = false;
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(private readonly ctx: AppContext) {}

  start(): void {
    if (this.timer) return;
    this.ctx.db.recoverPromptQueue();
    this.timer = setInterval(() => void this.tick(), 2000);
    void this.tick();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  async tick(): Promise<void> {
    if (this.busy || !this.ctx.fountain) return;
    this.busy = true;
    try {
      // One head per track, including failed heads: later instructions cannot
      // overtake one whose outcome needs a person. Other tracks still advance.
      await Promise.all(this.ctx.db.promptQueueHeads().map((row) => this.deliver(row)));
    } catch {
      // Leave claims intact for explicit recovery, and retry untouched rows on
      // the next tick. Never log prompt bodies or manufacture a successful send.
      console.error("switchyard: prompt queue sweep failed");
    } finally {
      this.busy = false;
    }
  }

  private authorized(row: Omit<PromptRow, "payload">): boolean {
    const { ctx } = this;
    const user = ctx.db.user(row.userId);
    try {
      if (!user) return false;
      const { track } = trackAccess(ctx, user, row.trackId);
      return !track.closedAt && !!track.conversationId;
    } catch { return false; }
  }

  private async deliver(row: Omit<PromptRow, "payload">): Promise<void> {
    const { ctx } = this;
    const fountain = ctx.fountain!;
    if (!this.authorized(row)) {
      ctx.db.setPromptStatus(row.id, "cancelled");
      return;
    }
    if (row.status !== "queued") return;
    const track = ctx.db.track(row.trackId)!;
    const project = ctx.db.project(track.projectId)!;
    try {
      const conversation = await fountain.getConversation(track.conversationId!);
      if (["running", "pending"].includes(conversation.status)) return;
      if (["failed", "terminated"].includes(conversation.status)) {
        ctx.db.setPromptStatus(row.id, "failed", "This conversation has ended. Start a new track and copy this prompt there.");
        return;
      }
      await prepareMachine(ctx, project, fountain);
    } catch {
      // Nothing has been sent. A read or credential refresh can safely retry.
      if (ctx.db.queuedPrompt(row.id)?.status === "queued") {
        ctx.db.setPromptStatus(row.id, "queued", "Waiting for the machine connection. Your prompt is saved and will retry automatically.");
      }
      return;
    }
    // Membership and cancellation may change during the network calls above.
    if (!this.authorized(row)) {
      ctx.db.setPromptStatus(row.id, "cancelled");
      return;
    }
    if (!ctx.db.claimPrompt(row.id)) return;
    try {
      const payload = JSON.parse(ctx.db.queuedPrompt(row.id)!.payload) as PromptPayload;
      const shared = ctx.db.membersOf(track.id).length > 0 || ctx.db.projectMembersOf(project.id).length > 0;
      await fountain.prompt(track.conversationId!, shared ? withAuthor(row.authorLogin, payload.prompt) : payload.prompt, payload.images);
      ctx.db.setPromptStatus(row.id, "sent");
      publish(project.id, { event: "turn", data: { trackId: track.id, status: "running" } }, new Set([
        project.userId,
        ...ctx.db.membersOf(track.id).map(member => member.id),
        ...ctx.db.projectMembersOf(project.id).map(member => member.id),
      ]));
    } catch (err) {
      // Fountain can reject an idle-looking track because another turn took
      // the sandbox's capacity meanwhile. A rejection is safe to retry.
      if (err instanceof FountainHttpError && err.status >= 400 && err.status < 500 && ["sandbox_at_capacity", "conversation_busy"].includes(err.code ?? "")) {
        ctx.db.setPromptStatus(row.id, "queued");
      } else if (err instanceof FountainHttpError && err.status >= 400 && err.status < 500) {
        ctx.db.setPromptStatus(row.id, "failed", "Delivery was refused. Check the machine and account settings, then retry this prompt.");
      } else {
        ctx.db.setPromptStatus(row.id, "unconfirmed", "Delivery could not be confirmed. Check the transcript before sending this again.");
      }
    }
  }
}
