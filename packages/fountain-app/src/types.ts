/**
 * The shapes the shared client libs read.
 *
 * Deliberately the minimum each lib actually touches, not a mirror of the
 * API. An app's own `api/types.ts` carries the full response shape and stays
 * where it is; because these are structural, a richer app-local `LogEvent`
 * (mission-control's, which also carries server-parsed `blocks`) is passed to
 * `blocksForTurn` without a cast.
 */

/** One line of a conversation's log stream. */
export interface LogEvent {
  id: number;
  kind: "output" | "stage" | string;
  stream: string | null;
  data: string | null;
  stage: string | null;
  state: string | null;
  turn_id: string | null;
  ts: string;
}
