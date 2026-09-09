/**
 * The Fountain client libs Ravix was built on.
 *
 * Four files that were byte-identical (or identical apart from the app's own
 * name) across a dozen repositories: the SSE reader, the ACP log parser, the
 * settings store and the PKCE sign-in. They live here once; each app keeps a
 * short `src/lib/<name>.ts` that binds its id and re-exports, so no call site
 * inside an app had to change when they moved.
 *
 * What is deliberately *not* here: `spec.ts` and `protocol.ts`. Those are the
 * prompt contract — what the app asks the agent for and how it reads the
 * answer back — and they are different in every app by design.
 */
export { SseParser, readSse } from "./sse";
export type { SseMessage, StreamOptions } from "./sse";
export { blocksForTurn, assistantText } from "./acp";
export type { Block } from "./acp";
export { createSettings, normalizeBaseUrl } from "./settings";
export type { Settings, SettingsStore } from "./settings";
export { createOAuth, redirectUri } from "./oauth";
export type { CallbackResult, OAuthClient } from "./oauth";
export type { LogEvent } from "./types";
