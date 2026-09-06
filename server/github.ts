/**
 * GitHub, in the two roles it plays here.
 *
 * **As the App.** A JWT signed with the App's private key buys an installation
 * access token, and that token is what clones a private repository onto the
 * machine and pushes the branch back. It is scoped to the repositories the
 * person chose when they installed, which is the whole reason sign-in is an
 * App rather than a plain OAuth app: an OAuth token is scoped to everything
 * the person can reach, and a machine that can read every repository you have
 * is not a machine you should let an agent loose on.
 *
 * **As the identity provider.** The same App has an OAuth client, so "sign in
 * with GitHub" and "which repositories may we see" are answers from one
 * registration rather than two. `GET /user/installations` with the *user's*
 * token is the join: it returns exactly the installations that both the App
 * has and this person can see, which is the correct answer to a question that
 * is easy to get wrong in the direction of showing somebody else's repos.
 *
 * An installation token lives for an hour. That is short enough to matter —
 * see `mintCloneToken` — and short enough to be worth it.
 */
import { createSign } from "node:crypto";
import type { GitHubAppConfig } from "./config";
import type { BranchRef, CheckRun, ChecksReport, IssueRef, PullRef, RepoRef } from "../shared/api";
import { HttpError } from "./http";

const UA = "switchyard (+https://switchyard.demo.managoat.com)";

export class GitHubError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

/** An installation token and when it stops working. */
interface MintedToken {
  token: string;
  expiresAtMs: number;
}

export class GitHub {
  /**
   * Where GitHub is.
   *
   * Configurable only so `mock/server.ts` can stand in for both hosts and the
   * whole app runs offline — the same reason the mock Fountain exists. In every
   * real deployment these are the defaults and nothing sets them.
   */
  private readonly api: string;
  private readonly web: string;

  /**
   * Installation tokens, cached until a minute before they expire.
   *
   * A minute of slack rather than none because the token is handed to a
   * machine that then uses it — a token that was valid when it left here and
   * expired in flight fails as `fatal: Authentication failed`, which reads
   * like a permissions problem and is not one.
   */
  private readonly tokens = new Map<number, MintedToken>();

  constructor(private readonly app: GitHubAppConfig) {
    this.api = app.apiUrl;
    this.web = app.webUrl;
  }

  // ── the App ──────────────────────────────────────────────────────────

  /**
   * A ten-minute JWT, which is the longest GitHub accepts.
   *
   * `iat` is backdated a minute on purpose: GitHub rejects a JWT whose `iat`
   * is in the future by its clock, and two machines' clocks are never quite
   * the same.
   */
  private appJwt(): string {
    const now = Math.floor(Date.now() / 1000);
    const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
    const payload = b64url(JSON.stringify({ iat: now - 60, exp: now + 9 * 60, iss: this.app.appId }));
    const signer = createSign("RSA-SHA256");
    signer.update(`${header}.${payload}`);
    // node:crypto takes PKCS#1 ("BEGIN RSA PRIVATE KEY") as GitHub issues it,
    // which WebCrypto does not — the reason this one function is not fetch.
    const sig = signer.sign(this.app.privateKeyPem).toString("base64url");
    return `${header}.${payload}.${sig}`;
  }

  /** A token for one installation, good for an hour, cached until it nearly is not. */
  async installationToken(installationId: number): Promise<string> {
    const cached = this.tokens.get(installationId);
    if (cached && cached.expiresAtMs > Date.now() + 60_000) return cached.token;
    const body = await this.request<{ token: string; expires_at: string }>(
      "POST",
      `/app/installations/${installationId}/access_tokens`,
      { auth: `Bearer ${this.appJwt()}` },
    );
    const minted = { token: body.token, expiresAtMs: Date.parse(body.expires_at) };
    this.tokens.set(installationId, minted);
    return minted.token;
  }

  /**
   * The token that goes onto a machine so git can clone and push.
   *
   * Named separately from `installationToken` because the call sites mean
   * different things and one of them has a deadline: this token is written
   * into the project's vault, and Fountain hands the vault to the sandbox when
   * a session starts. An hour later it is dead. So every path that is about to
   * make the machine talk to GitHub — opening a track, sending a turn —
   * re-mints first. The cache above makes that nearly free.
   */
  mintCloneToken(installationId: number): Promise<string> {
    return this.installationToken(installationId);
  }

  // ── signing somebody in ──────────────────────────────────────────────

  /** Where a browser goes to sign in. `state` is ours and comes back untouched. */
  authorizeUrl(redirectUri: string, state: string): string {
    const qs = new URLSearchParams({
      client_id: this.app.clientId,
      redirect_uri: redirectUri,
      state,
      // A GitHub App's user token gets its repository access from the
      // installation, not from scopes. `read:user` is only so that a person
      // with no public email still resolves to a name in the sidebar.
      scope: "read:user",
    });
    return `${this.web}/login/oauth/authorize?${qs}`;
  }

  /** Where a browser goes to install the App, or to change which repos it sees. */
  installUrl(state?: string): string {
    const qs = state ? `?${new URLSearchParams({ state })}` : "";
    return `${this.web}/apps/${this.app.slug}/installations/new${qs}`;
  }

  async exchangeCode(code: string, redirectUri: string): Promise<string> {
    const res = await fetch(`${this.web}/login/oauth/access_token`, {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/json", "user-agent": UA },
      body: JSON.stringify({
        client_id: this.app.clientId,
        client_secret: this.app.clientSecret,
        code,
        redirect_uri: redirectUri,
      }),
    });
    const body = (await res.json().catch(() => ({}))) as { access_token?: string; error_description?: string; error?: string };
    if (!res.ok || !body.access_token) {
      // GitHub answers 200 with an error body here, so the status is not the
      // check. `bad_verification_code` is the ordinary one: a reloaded
      // callback, or a code already spent.
      throw new GitHubError(400, body.error_description ?? body.error ?? "GitHub would not exchange that code.");
    }
    return body.access_token;
  }

  /**
   * One GitHub account, by login, read as the App itself.
   *
   * Used to invite somebody who has never signed in here: without this, an
   * invitation could only name a row we already had, and the first person you
   * want to work with is by definition not one of them. Reading it as the App
   * rather than as the caller means the answer does not depend on whose token
   * asked, and the numeric id it returns is what the invitation is stored
   * against — see `track_invites`.
   */
  async userByLogin(login: string): Promise<{ id: number; login: string; name: string | null; avatar_url: string } | null> {
    try {
      return await this.request("GET", `/users/${encodeURIComponent(login)}`, { auth: `Bearer ${this.appJwt()}` });
    } catch (err) {
      if (err instanceof GitHubError && err.status === 404) return null;
      throw err;
    }
  }

  async viewer(userToken: string): Promise<{ id: number; login: string; name: string | null; avatar_url: string }> {
    return this.request("GET", "/user", { auth: `Bearer ${userToken}` });
  }

  // ── what this person can see ─────────────────────────────────────────

  /**
   * The installations this person can see *and* this App has.
   *
   * The intersection is the point. Asking the App for its installations would
   * list every account that has ever installed switchyard; asking the user's
   * token for theirs lists only the ones they are a member of. The second
   * question is the one the repository picker is actually asking.
   */
  async installationsFor(userToken: string): Promise<{ id: number; account: string; avatarUrl: string | null }[]> {
    const body = await this.request<{
      installations: { id: number; account: { login: string; avatar_url?: string } | null }[];
    }>("GET", "/user/installations?per_page=100", { auth: `Bearer ${userToken}` });
    return (body.installations ?? []).map((i) => ({
      id: i.id,
      account: i.account?.login ?? "(unknown)",
      avatarUrl: i.account?.avatar_url ?? null,
    }));
  }

  /**
   * Every repository this person's installations grant, newest activity first.
   *
   * Sorted by `pushed_at` rather than by name, because the picker is opened by
   * somebody who wants the thing they were just working on and the alphabet
   * has no opinion about that. Paged to a thousand: an installation with more
   * repositories than that wants a search box, which the picker has.
   */
  async repositories(userToken: string, installationId: number): Promise<RepoRef[]> {
    const out: RepoRef[] = [];
    for (let page = 1; page <= 10; page++) {
      const body = await this.request<{ repositories: RawRepo[] }>(
        "GET",
        `/user/installations/${installationId}/repositories?per_page=100&page=${page}`,
        { auth: `Bearer ${userToken}` },
      );
      const batch = body.repositories ?? [];
      for (const r of batch) out.push(toRepoRef(r, installationId));
      if (batch.length < 100) break;
    }
    return out.sort((a, b) => (b.pushedAt ?? "").localeCompare(a.pushedAt ?? ""));
  }

  /** One repository, read as the installation — so it works for private ones. */
  async repository(installationId: number, fullName: string): Promise<RepoRef> {
    const token = await this.installationToken(installationId);
    const raw = await this.request<RawRepo>("GET", `/repos/${fullName}`, { auth: `Bearer ${token}` });
    return toRepoRef(raw, installationId);
  }

  // ── the three ways to start a track ──────────────────────────────────

  async branches(installationId: number, fullName: string, defaultBranch: string): Promise<BranchRef[]> {
    const token = await this.installationToken(installationId);
    const raw = await this.request<{ name: string; commit: { sha: string } }[]>(
      "GET",
      `/repos/${fullName}/branches?per_page=100`,
      { auth: `Bearer ${token}` },
    );
    return raw
      .map((b) => ({ name: b.name, sha: b.commit.sha, isDefault: b.name === defaultBranch }))
      .sort((a, b) => Number(b.isDefault) - Number(a.isDefault) || a.name.localeCompare(b.name));
  }

  async pulls(installationId: number, fullName: string): Promise<PullRef[]> {
    const token = await this.installationToken(installationId);
    const raw = await this.request<RawPull[]>(
      "GET",
      `/repos/${fullName}/pulls?state=open&sort=updated&direction=desc&per_page=50`,
      { auth: `Bearer ${token}` },
    );
    return raw.map(toPullRef);
  }

  /**
   * Open issues, without the pull requests.
   *
   * GitHub's issues endpoint returns pull requests too — they are issues as
   * far as the data model is concerned — and a picker with a PRs tab beside an
   * Issues tab showing the same rows twice is a bug people notice immediately.
   */
  async issues(installationId: number, fullName: string): Promise<IssueRef[]> {
    const token = await this.installationToken(installationId);
    const raw = await this.request<RawIssue[]>(
      "GET",
      `/repos/${fullName}/issues?state=open&sort=updated&direction=desc&per_page=50`,
      { auth: `Bearer ${token}` },
    );
    return raw
      .filter((i) => !i.pull_request)
      .map((i) => ({
        number: i.number,
        title: i.title,
        author: i.user?.login ?? null,
        labels: (i.labels ?? []).map((l) => (typeof l === "string" ? l : l.name)),
        updatedAt: i.updated_at,
      }));
  }

  // ── what GitHub thinks of a branch ───────────────────────────────────

  /**
   * The Checks tab.
   *
   * A branch that has never been pushed is the ordinary case in a new track,
   * not an error — so `pushed: false` is a first-class answer and the panel
   * renders "nothing pushed yet" rather than an empty list that looks broken.
   */
  async checks(installationId: number, fullName: string, ref: string): Promise<ChecksReport> {
    const token = await this.installationToken(installationId);
    let sha: string | null = null;
    try {
      const branch = await this.request<{ commit: { sha: string } }>(
        "GET",
        `/repos/${fullName}/branches/${encodeURIComponent(ref)}`,
        { auth: `Bearer ${token}` },
      );
      sha = branch.commit.sha;
    } catch (err) {
      if (!(err instanceof GitHubError && err.status === 404)) throw err;
      // Merged PRs remain useful after GitHub deletes their head branch.
    }

    const [runs, pulls] = await Promise.all([
      sha ? this.request<{ check_runs: RawCheckRun[] }>("GET", `/repos/${fullName}/commits/${sha}/check-runs?per_page=50`, {
        auth: `Bearer ${token}`,
      }) : Promise.resolve({ check_runs: [] as RawCheckRun[] }),
      // `state=all`, not `state=open`. A branch whose pull request has been
      // merged is the *most* interesting case — it is the one where the work
      // landed — and asking only for open ones answered "no pull request for
      // this branch" beside two green checks that plainly came from one.
      this.request<RawPull[]>(
        "GET",
        `/repos/${fullName}/pulls?state=all&per_page=20&head=${encodeURIComponent(fullName.split("/")[0] + ":" + ref)}`,
        { auth: `Bearer ${token}` },
      ),
    ]);

    // An open one if there is one, else the most recently updated — which for
    // a finished branch is the pull request that merged it.
    const ranked = [...pulls].sort(
      (a, b) => Number(!!a.merged_at || a.state === "closed") - Number(!!b.merged_at || b.state === "closed") ||
        b.updated_at.localeCompare(a.updated_at),
    );

    return {
      ref,
      sha,
      pushed: sha !== null,
      runs: (runs.check_runs ?? []).map(
        (r): CheckRun => ({
          name: r.name,
          status: r.status,
          conclusion: r.conclusion,
          url: r.html_url ?? null,
          startedAt: r.started_at ?? null,
          completedAt: r.completed_at ?? null,
        }),
      ),
      pull: ranked[0] ? toPullRef(ranked[0]) : null,
    };
  }

  /** Open a pull request for a branch the machine has already pushed. */
  async openPull(
    installationId: number,
    fullName: string,
    input: { head: string; base: string; title: string; body: string; draft: boolean },
  ): Promise<PullRef & { url: string }> {
    const token = await this.installationToken(installationId);
    const raw = await this.request<RawPull & { html_url: string }>("POST", `/repos/${fullName}/pulls`, {
      auth: `Bearer ${token}`,
      body: input,
    });
    return { ...toPullRef(raw), url: raw.html_url };
  }

  // ── the one request ──────────────────────────────────────────────────

  private async request<T>(
    method: string,
    path: string,
    init: { auth: string; body?: unknown },
  ): Promise<T> {
    const res = await fetch(path.startsWith("http") ? path : `${this.api}${path}`, {
      method,
      headers: {
        accept: "application/vnd.github+json",
        authorization: init.auth,
        "user-agent": UA,
        "x-github-api-version": "2022-11-28",
        ...(init.body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      signal: AbortSignal.timeout(20_000),
    });
    if (res.status === 204) return undefined as T;
    const text = await res.text();
    if (!res.ok) {
      let message = `GitHub said ${res.status}.`;
      try {
        const parsed = JSON.parse(text) as { message?: string; errors?: { message?: string }[] };
        if (parsed.message) message = parsed.message;
        const first = parsed.errors?.[0]?.message;
        if (first) message += ` ${first}`;
      } catch {
        /* not JSON — the status line is the whole story */
      }
      throw new GitHubError(res.status, message);
    }
    return (text ? JSON.parse(text) : undefined) as T;
  }
}

/** A GitHub failure as one of ours, keeping the part a person can act on. */
export function asHttpError(err: unknown, whatFor: string): HttpError {
  if (err instanceof GitHubError) {
    if (err.status === 401 || err.status === 403) {
      return new HttpError(502, "github_rejected", `GitHub would not let switchyard ${whatFor}: ${err.message}`);
    }
    if (err.status === 404) return new HttpError(404, "github_not_found", err.message);
    return new HttpError(err.status >= 500 ? 502 : err.status, "github_error", err.message);
  }
  return new HttpError(502, "github_unreachable", `Could not reach GitHub to ${whatFor}.`);
}

// ── the shapes GitHub actually sends ───────────────────────────────────

interface RawRepo {
  full_name: string;
  name: string;
  owner: { login: string };
  private: boolean;
  default_branch: string;
  description: string | null;
  pushed_at: string | null;
  language: string | null;
}

interface RawPull {
  number: number;
  title: string;
  user: { login: string } | null;
  head: { ref: string };
  base: { ref: string };
  draft?: boolean;
  updated_at: string;
  state?: string;
  merged_at?: string | null;
  html_url?: string;
}

interface RawIssue {
  number: number;
  title: string;
  user: { login: string } | null;
  labels: (string | { name: string })[] | null;
  updated_at: string;
  pull_request?: unknown;
}

interface RawCheckRun {
  name: string;
  status: string;
  conclusion: string | null;
  html_url?: string | null;
  started_at?: string | null;
  completed_at?: string | null;
}

function toRepoRef(r: RawRepo, installationId: number): RepoRef {
  return {
    fullName: r.full_name,
    owner: r.owner.login,
    name: r.name,
    private: r.private,
    defaultBranch: r.default_branch,
    description: r.description,
    pushedAt: r.pushed_at,
    language: r.language,
    installationId,
  };
}

function toPullRef(p: RawPull): PullRef {
  return {
    number: p.number,
    title: p.title,
    author: p.user?.login ?? null,
    headRef: p.head.ref,
    baseRef: p.base.ref,
    draft: !!p.draft,
    updatedAt: p.updated_at,
    state: p.merged_at ? "merged" : p.state === "closed" ? "closed" : "open",
    url: p.html_url ?? null,
  };
}

function b64url(s: string): string {
  return Buffer.from(s, "utf8").toString("base64url");
}
