/**
 * Where an app points and how it authenticates, kept in the browser.
 *
 * Every Fountain app this was written for stored exactly this under its own `<app>.settings`
 * key, so the only thing that ever differed between the copies was that
 * string. `createSettings` takes it; the app keeps a four-line
 * `src/lib/settings.ts` that binds its own id and re-exports, which is what
 * lets every call site in the app stay as it was.
 */

/** Where the app points and how it authenticates. Stored locally, in this browser only. */
export interface Settings {
  baseUrl: string;
  apiKey: string;
  /** How the key was obtained — an OAuth key is revoked on sign-out. */
  via?: "paste" | "oauth";
}

export interface SettingsStore {
  loadSettings(): Settings | null;
  saveSettings(s: Settings): void;
  clearSettings(): void;
}

export function normalizeBaseUrl(url: string): string {
  return url.trim().replace(/\/+$/, "");
}

/** The `<appId>.settings` store, bound to one app. */
export function createSettings(appId: string): SettingsStore {
  const KEY = `${appId}.settings`;

  return {
    loadSettings(): Settings | null {
      try {
        const raw = localStorage.getItem(KEY);
        if (!raw) return null;
        const parsed = JSON.parse(raw) as Partial<Settings>;
        if (typeof parsed.baseUrl !== "string" || typeof parsed.apiKey !== "string") return null;
        return { baseUrl: normalizeBaseUrl(parsed.baseUrl), apiKey: parsed.apiKey, via: parsed.via === "oauth" ? "oauth" : "paste" };
      } catch {
        return null;
      }
    },

    saveSettings(s: Settings): void {
      localStorage.setItem(KEY, JSON.stringify({ baseUrl: normalizeBaseUrl(s.baseUrl), apiKey: s.apiKey, via: s.via ?? "paste" }));
    },

    clearSettings(): void {
      localStorage.removeItem(KEY);
    },
  };
}
