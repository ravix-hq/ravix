/**
 * The server's configuration, from the environment.
 *
 * Switchyard needs more of it than its siblings, and the reason is the one
 * structural difference: **the browser holds no credential for anything**.
 * Sign-in is GitHub, so nobody here has a Fountain account to spend; every
 * machine runs on this server's Fountain key. That is a real trade — it is
 * written down in the README under "Whose account is this" — and it puts four
 * separate secrets in this process.
 *
 *   FOUNTAIN_URL          the Fountain every machine is built on
 *   FOUNTAIN_API_KEY      the account it is built on. Required.
 *   DATA_DIR              SQLite, and a generated secret if none is given
 *   SWITCHYARD_SECRET     encrypts stored tokens; generated into DATA_DIR/secret
 *   PORT                  listen port (8080)
 *   STATIC_DIR            the built SPA; unset serves none (dev, behind Vite)
 *   PUBLIC_URL            this server as GitHub reaches it. Required for OAuth.
 *
 * The GitHub App, all of which must be present together or none of it works:
 *
 *   GITHUB_APP_ID         numeric
 *   GITHUB_APP_SLUG       the URL name, for /apps/<slug>/installations/new
 *   GITHUB_CLIENT_ID      the App's OAuth client, for signing people in
 *   GITHUB_CLIENT_SECRET
 *   GITHUB_PRIVATE_KEY    PKCS#8 or PKCS#1 PEM. Newlines may be `\n`-escaped,
 *                         because every secret store mangles them differently.
 *   GITHUB_WEBHOOK_SECRET optional; without it installation events are ignored
 *
 * And the one that is genuinely optional:
 *
 *   SPRITES_TOKEN         with it, the terminal and the run panel are live.
 *                         Without it they render a designed empty state and
 *                         say exactly what is missing. See `server/sprites.ts`.
 *   SPRITES_URL           defaults to https://api.sprites.dev
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomToken } from "./crypto";

export interface GitHubAppConfig {
  appId: string;
  slug: string;
  clientId: string;
  clientSecret: string;
  privateKeyPem: string;
  webhookSecret: string | null;
  /** `https://api.github.com`, unless the mock is standing in. */
  apiUrl: string;
  /** `https://github.com`, likewise. */
  webUrl: string;
}

export interface Config {
  sharedBrowser?: boolean;
  nativePreviewExperiment?: boolean;
  nativeHelloIosSha256?: string;
  fountainUrl: string;
  fountainKey: string | null;
  dataDir: string;
  dbPath: string;
  secret: string;
  port: number;
  staticDir: string | null;
  /** Without a trailing slash. Falls back to localhost so `bun run server` works. */
  publicUrl: string;
  github: GitHubAppConfig | null;
  sprites: { token: string; baseUrl: string } | null;
  sessionMaxAgeMs: number;
  previews?: { domain: string; port: number; protocol: "https:" | "http:"; publicPort: string } | null;
}

const DAY_MS = 24 * 60 * 60 * 1000;

export function loadConfig(env: Record<string, string | undefined> = process.env): Config {
  const fountainUrl = (env.FOUNTAIN_URL ?? "https://managoat.com").trim().replace(/\/+$/, "");
  const dataDir = env.DATA_DIR ?? "./data";
  mkdirSync(dataDir, { recursive: true });

  // A generated secret keeps a fresh deployment working, but it then lives
  // beside the data it protects — which is why the k8s Secret is the right
  // answer and this is only the fallback. Same trade as paddock and salon.
  let secret = env.SWITCHYARD_SECRET?.trim() ?? "";
  if (!secret) {
    const file = join(dataDir, "secret");
    if (existsSync(file)) secret = readFileSync(file, "utf8").trim();
    else {
      secret = randomToken();
      writeFileSync(file, secret, { mode: 0o600 });
    }
  }

  const staticDir = env.STATIC_DIR === undefined ? null : env.STATIC_DIR.trim() || null;
  const publicUrl = (env.PUBLIC_URL?.trim().replace(/\/+$/, "") || "http://localhost:5183").trim();

  return {
    sharedBrowser: env.SHARED_BROWSER === "1",
    nativePreviewExperiment: env.NATIVE_PREVIEW_EXPERIMENT === "1",
    nativeHelloIosSha256: /^[a-f0-9]{64}$/.test(env.NATIVE_HELLO_IOS_SHA256 ?? "") ? env.NATIVE_HELLO_IOS_SHA256 : undefined,
    fountainUrl,
    fountainKey: env.FOUNTAIN_API_KEY?.trim() || null,
    dataDir,
    dbPath: join(dataDir, "switchyard.sqlite"),
    secret,
    port: Number(env.PORT ?? 8081),
    staticDir,
    publicUrl,
    github: githubConfig(env),
    sprites: spritesConfig(env),
    sessionMaxAgeMs: 30 * DAY_MS,
    previews: previewConfig(env, publicUrl),
  };
}

function previewConfig(env: Record<string, string | undefined>, publicUrl: string): Config["previews"] {
  const domain = env.PREVIEW_DOMAIN?.trim().toLowerCase();
  if (!domain) return null;
  const appHost = new URL(publicUrl).hostname;
  if (!/^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z]+$/.test(domain) || domain === appHost || (appHost !== "localhost" && domain.endsWith(`.${appHost}`)) || appHost.endsWith(`.${domain}`)) {
    throw new Error("PREVIEW_DOMAIN must be a dedicated domain outside the Switchyard application host.");
  }
  const local = domain.endsWith(".localhost");
  return { domain, port: Number(env.PREVIEW_PORT || 8082), protocol: local ? "http:" : "https:", publicPort: local ? `:${env.PREVIEW_PORT || 8082}` : "" };
}

/**
 * All of the App or none of it.
 *
 * A half-configured GitHub App is the worst state to be in: sign-in works,
 * repositories do not, and the failure surfaces four screens later as an empty
 * list rather than as a missing variable. So the config is a single nullable
 * object, and `SessionInfo.capabilities.github` tells the UI which world it is
 * in before it renders a picker nobody can use.
 */
function githubConfig(env: Record<string, string | undefined>): GitHubAppConfig | null {
  const appId = env.GITHUB_APP_ID?.trim();
  const clientId = env.GITHUB_CLIENT_ID?.trim();
  const clientSecret = env.GITHUB_CLIENT_SECRET?.trim();
  const rawKey = env.GITHUB_PRIVATE_KEY;
  if (!appId || !clientId || !clientSecret || !rawKey) return null;
  return {
    appId,
    slug: env.GITHUB_APP_SLUG?.trim() || "switchyard",
    clientId,
    clientSecret,
    privateKeyPem: normalizePem(rawKey),
    webhookSecret: env.GITHUB_WEBHOOK_SECRET?.trim() || null,
    apiUrl: (env.GITHUB_API_URL?.trim() || "https://api.github.com").replace(/\/+$/, ""),
    webUrl: (env.GITHUB_WEB_URL?.trim() || "https://github.com").replace(/\/+$/, ""),
  };
}

/**
 * A PEM as it survives being put in a secret store.
 *
 * Kubernetes Secrets, `.env` files, GitHub Actions secrets and a shell heredoc
 * each preserve a different amount of the original: literal newlines, `\n`
 * escapes, or the whole thing on one line with the header and footer intact.
 * All three arrive here and all three have to work, because the alternative is
 * a deployment that fails with `error:1E08010C:DECODER routines::unsupported`
 * and no clue which of them did it.
 */
export function normalizePem(raw: string): string {
  let s = raw.trim();
  if (s.startsWith('"') && s.endsWith('"')) s = s.slice(1, -1);
  s = s.replace(/\\n/g, "\n").replace(/\r\n/g, "\n").trim();
  if (s.includes("\n")) return s;
  // One long line: re-wrap the body between the header and footer.
  const m = /^(-----BEGIN [A-Z ]+-----)\s*(.*?)\s*(-----END [A-Z ]+-----)$/.exec(s);
  if (!m) return s;
  const body = m[2]!.replace(/\s+/g, "").match(/.{1,64}/g) ?? [];
  return [m[1]!, ...body, m[3]!].join("\n");
}

function spritesConfig(env: Record<string, string | undefined>): { token: string; baseUrl: string } | null {
  const token = env.SPRITES_TOKEN?.trim();
  if (!token) return null;
  return { token, baseUrl: (env.SPRITES_URL?.trim() || "https://api.sprites.dev").replace(/\/+$/, "") };
}
