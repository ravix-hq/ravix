export interface PreviewConfig {
  directory: string;
  command: string;
  readinessPath: string;
}
export const AGENT_PREVIEW_START = "[switchyard preview tools for this turn]";
export const AGENT_PREVIEW_END = "[/switchyard preview tools]";
export function visiblePreviewPrompt(prompt: string): string {
  if (!prompt.startsWith(`${AGENT_PREVIEW_START}\n`)) return prompt;
  const end = prompt.indexOf(`\n${AGENT_PREVIEW_END}\n\n`);
  return end < 0 ? prompt : prompt.slice(end + AGENT_PREVIEW_END.length + 3);
}
export type PreviewState = "stopped" | "starting" | "ready" | "failed";
export interface PreviewInfo {
  available: boolean;
  unavailableReason: string | null;
  config: PreviewConfig | null;
  override: PreviewConfig | null;
  state: PreviewState;
  error: string | null;
  logs: string;
  url: string | null;
}
