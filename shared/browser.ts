/** A Switchyard session has one shared identity. Actors own control, not profiles. */
export interface BrowserActor { id: string; label: string; kind: "human" | "agent" }
export interface BrowserTab { id: string; url: string; title: string }
export interface BrowserState {
  tabs: BrowserTab[];
  controller: (BrowserActor & { expires: number }) | null;
  revision: string;
  sequence: number;
}
export interface BrowserCheckpoint { id: string; sessionId: string; label: string; createdAt: string }
export interface BrowserInfo {
  available: boolean;
  session: { id: string; profile: "shared"; state: "stopped" | "ready" | "failed"; error: string | null } | null;
  checkpoints: BrowserCheckpoint[];
}
export type BrowserCommand =
  | { action: "status" | "acquire" | "release" }
  | { action: "open"; url: string }
  | { action: "navigate"; tabId: string; url: string }
  | { action: "close" | "back" | "forward" | "reload" | "inspect" | "screenshot"; tabId: string }
  | { action: "click"; tabId: string; x: number; y: number }
  | { action: "scroll"; tabId: string; x: number; y: number; deltaX: number; deltaY: number }
  | { action: "text"; tabId: string; text: string }
  | { action: "key"; tabId: string; key: string };
export interface BrowserResult extends BrowserState { text?: string; image?: string; tabId?: string }

export const BROWSER_WIDTH = 1280;
export const BROWSER_HEIGHT = 800;
export const BROWSER_TOOLS_START = "[switchyard browser tools for this turn]";
export const BROWSER_TOOLS_END = "[/switchyard browser tools]";
export function visibleBrowserPrompt(prompt: string): string {
  if (!prompt.startsWith(`${BROWSER_TOOLS_START}\n`)) return prompt;
  const end = prompt.indexOf(`\n${BROWSER_TOOLS_END}\n\n`);
  return end < 0 ? prompt : prompt.slice(end + BROWSER_TOOLS_END.length + 3);
}
