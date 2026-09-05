import type { AppContext } from "./context";
import { randomToken, sha256 } from "./crypto";
import { cookieValue } from "./http";

const MAX_AGE = 15 * 60;
const validState = (state: string) => /^[A-Za-z0-9_-]{24}$/.test(state);

// One cookie per attempt lets sign-in and invite links coexist in several tabs.
// The URL carries only state; the database key also requires a browser secret.
export async function beginOAuth(ctx: AppContext, req: Request, kind: string, redirect: string | null) {
  const state = randomToken(18);
  const secret = randomToken();
  ctx.db.putState(await sha256(`${state}:${secret}`), kind, redirect);
  return { state, cookie: oauthCookie(req, state, secret, MAX_AGE) };
}

export async function takeOAuth(ctx: AppContext, req: Request, state: string | null) {
  if (!state || !validState(state)) return null;
  const secret = cookieValue(req, `switchyard_oauth_${state}`);
  if (!secret) return null;
  return ctx.db.takeState(await sha256(`${state}:${secret}`));
}

export function clearOAuth(req: Request, state: string | null): string | null {
  return state && validState(state) ? oauthCookie(req, state, "", 0) : null;
}

function oauthCookie(req: Request, state: string, value: string, maxAge: number): string {
  const https = (req.headers.get("x-forwarded-proto")?.split(",")[0]?.trim() ?? new URL(req.url).protocol.replace(":", "")) === "https";
  return `switchyard_oauth_${state}=${value}; Path=/api/auth/callback; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${https ? "; Secure" : ""}`;
}
