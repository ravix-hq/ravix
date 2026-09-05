export interface PreviewConfig {
  directory: string;
  command: string;
  readinessPath: string;
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
