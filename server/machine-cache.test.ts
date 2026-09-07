import { beforeEach, expect, mock, test } from "bun:test";
import type { ConversationSummary, Fountain } from "./fountain";
import { forgetProject, liveConversations, resetMachineCache, spriteName, SPRITE_TTL_MS, TTL_MS } from "./machine-cache";

const project = { id: "p1", agentId: "a1" };
const row = { id: "c1", sandbox_id: "s1", status: "idle", inserted_at: "2026-09-07" } as unknown as ConversationSummary;

function fountain(rows: unknown[] = [row]) {
  const listConversations = mock(async (_agentId?: string) => rows);
  return { fountain: { listConversations } as unknown as Fountain, listConversations };
}

beforeEach(() => resetMachineCache());

test("a burst of reads within the TTL is one call, and concurrent misses share it", async () => {
  const f = fountain();
  const [a, b, c] = await Promise.all([
    liveConversations(f.fountain, project, { nowMs: 0 }),
    liveConversations(f.fountain, project, { nowMs: 0 }),
    liveConversations(f.fountain, project, { nowMs: 1_000 }),
  ]);
  expect(f.listConversations).toHaveBeenCalledTimes(1);
  // Narrowed to the project's agent, never the whole account.
  expect(f.listConversations.mock.calls[0]?.[0]).toBe("a1");
  expect(a).toBe(b);
  expect(b).toBe(c);
});

test("the memo expires", async () => {
  const f = fountain();
  await liveConversations(f.fountain, project, { nowMs: 0 });
  await liveConversations(f.fountain, project, { nowMs: TTL_MS - 1 });
  expect(f.listConversations).toHaveBeenCalledTimes(1);
  await liveConversations(f.fountain, project, { nowMs: TTL_MS });
  expect(f.listConversations).toHaveBeenCalledTimes(2);
});

test("a fresh read asks Fountain and refreshes the memo for everyone else", async () => {
  const f = fountain();
  await liveConversations(f.fountain, project, { nowMs: 0 });
  await liveConversations(f.fountain, project, { nowMs: 1, fresh: true });
  expect(f.listConversations).toHaveBeenCalledTimes(2);
  await liveConversations(f.fountain, project, { nowMs: 2 });
  expect(f.listConversations).toHaveBeenCalledTimes(2);
});

test("forgetting a project drops its memo and nobody else's", async () => {
  const f = fountain();
  const other = { id: "p2", agentId: "a2" };
  await liveConversations(f.fountain, project, { nowMs: 0 });
  await liveConversations(f.fountain, other, { nowMs: 0 });
  forgetProject(project.id);
  await liveConversations(f.fountain, project, { nowMs: 1 });
  await liveConversations(f.fountain, other, { nowMs: 1 });
  expect(f.listConversations).toHaveBeenCalledTimes(3);
});

test("two clients do not share an answer", async () => {
  const f = fountain();
  const g = fountain([]);
  expect(await liveConversations(f.fountain, project, { nowMs: 0 })).toEqual([row]);
  expect(await liveConversations(g.fountain, project, { nowMs: 0 })).toEqual([]);
});

test("a failed read is not remembered", async () => {
  const listConversations = mock(async () => {
    throw new Error("boom");
  });
  const f = { listConversations } as unknown as Fountain;
  await expect(liveConversations(f, project, { nowMs: 0 })).rejects.toThrow("boom");
  await expect(liveConversations(f, project, { nowMs: 1 })).rejects.toThrow("boom");
  expect(listConversations).toHaveBeenCalledTimes(2);
});

test("a sprite name stands for a minute; a missing one only briefly", async () => {
  const f = fountain().fountain;
  const named = mock(async () => "sprite-1");
  await spriteName(f, "s1", named, 0);
  await spriteName(f, "s1", named, SPRITE_TTL_MS - 1);
  expect(named).toHaveBeenCalledTimes(1);
  await spriteName(f, "s1", named, SPRITE_TTL_MS);
  expect(named).toHaveBeenCalledTimes(2);

  const missing = mock(async () => null);
  await spriteName(f, "s2", missing, 0);
  await spriteName(f, "s2", missing, TTL_MS - 1);
  expect(missing).toHaveBeenCalledTimes(1);
  await spriteName(f, "s2", missing, TTL_MS);
  expect(missing).toHaveBeenCalledTimes(2);
});
