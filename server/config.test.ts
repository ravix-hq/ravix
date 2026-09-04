import { expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { loadConfig, normalizePem } from "./config";
import { GitHub } from "./github";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dataDir = () => mkdtempSync(join(tmpdir(), "switchyard-"));

const { privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs1", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

test("a PEM survives every mangling a secret store applies to it", () => {
  // Literal newlines, `\n` escapes, surrounding quotes and the whole thing on
  // one line all arrive here from Kubernetes Secrets, .env files and GitHub
  // Actions respectively. All three have to work: the alternative is a
  // deployment that fails with a DECODER error naming none of them.
  const canonical = privateKey.trim();
  expect(normalizePem(canonical)).toBe(canonical);
  expect(normalizePem(canonical.replace(/\n/g, "\\n"))).toBe(canonical);
  expect(normalizePem(`"${canonical.replace(/\n/g, "\\n")}"`)).toBe(canonical);

  const oneLine = canonical.replace(/\n/g, " ").replace(/\s+/g, " ");
  const rewrapped = normalizePem(oneLine);
  expect(rewrapped.startsWith("-----BEGIN RSA PRIVATE KEY-----\n")).toBe(true);
  expect(rewrapped.endsWith("\n-----END RSA PRIVATE KEY-----")).toBe(true);
  expect(rewrapped.replace(/\s+/g, "")).toBe(canonical.replace(/\s+/g, ""));
});

test("the GitHub App is all present or entirely absent", () => {
  const base = {
    DATA_DIR: dataDir(),
    GITHUB_APP_ID: "1",
    GITHUB_CLIENT_ID: "Iv1.x",
    GITHUB_CLIENT_SECRET: "s",
    GITHUB_PRIVATE_KEY: privateKey,
  };
  expect(loadConfig(base).github).not.toBeNull();
  // A half-configured App is the worst state: sign-in works, repositories do
  // not, and the failure surfaces four screens later as an empty list.
  for (const missing of ["GITHUB_APP_ID", "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "GITHUB_PRIVATE_KEY"]) {
    expect(loadConfig({ ...base, [missing]: undefined }).github).toBeNull();
  }
});

test("Sprites is genuinely optional, and Fountain is genuinely not", () => {
  const dir = dataDir();
  expect(loadConfig({ DATA_DIR: dir }).sprites).toBeNull();
  expect(loadConfig({ DATA_DIR: dir, SPRITES_TOKEN: "t" }).sprites?.baseUrl).toBe("https://api.sprites.dev");
  expect(loadConfig({ DATA_DIR: dir }).fountainKey).toBeNull();
});

test("a generated secret is written once and reused, so restarts do not orphan sessions", () => {
  const dir = dataDir();
  const first = loadConfig({ DATA_DIR: dir }).secret;
  expect(first.length).toBeGreaterThan(16);
  expect(loadConfig({ DATA_DIR: dir }).secret).toBe(first);
});

test("the App signs a JWT node accepts from a PKCS#1 key", () => {
  // GitHub issues PKCS#1 ("BEGIN RSA PRIVATE KEY"), which WebCrypto will not
  // import — the single reason `appJwt` uses node:crypto rather than fetch's
  // neighbours. If this throws, every installation token call is dead.
  const gh = new GitHub({
    appId: "1",
    slug: "switchyard",
    clientId: "Iv1.x",
    clientSecret: "s",
    privateKeyPem: normalizePem(privateKey),
    webhookSecret: null,
    apiUrl: "https://api.github.com",
    webUrl: "https://github.com",
  });
  const url = gh.authorizeUrl("http://localhost:5183/api/auth/callback", "st8");
  expect(url).toContain("client_id=Iv1.x");
  expect(url).toContain("state=st8");
  // `redirect_uri` must round-trip exactly; GitHub compares it literally.
  expect(url).toContain(encodeURIComponent("http://localhost:5183/api/auth/callback"));
  expect(gh.installUrl()).toBe("https://github.com/apps/switchyard/installations/new");
});
