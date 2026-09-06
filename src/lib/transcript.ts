import type { LogEvent } from "../../shared/fountain-types";
import type { TurnRecord } from "../../shared/api";

/** Snapshots and SSE replay overlap and can arrive in either order. */
export function mergeEvents(current: LogEvent[], incoming: LogEvent[]): LogEvent[] {
  const events = new Map(current.map(event => [event.id, event]));
  for (const event of incoming) events.set(event.id, event);
  return [...events.values()].sort((a, b) => a.id - b.id);
}

export function mergeTurns(current: TurnRecord[], incoming: TurnRecord[]): TurnRecord[] {
  const turns = new Map(current.map(turn => [turn.id, turn]));
  for (const turn of incoming) turns.set(turn.id, turn);
  return [...turns.values()].sort((a, b) =>
    (a.insertedAt ?? "").localeCompare(b.insertedAt ?? ""));
}
