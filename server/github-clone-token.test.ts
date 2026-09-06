import { expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { GitHub } from "./github";

test("machine preparations mint fresh tokens while ordinary API calls reuse the cache", async () => {
  let minted = 0;
  const server = Bun.serve({ port: 0, fetch() {
    return Response.json({ token: `token-${++minted}`, expires_at: new Date(Date.now() + 3_600_000).toISOString() });
  } });
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const gh = new GitHub({
    appId: "1", clientId: "test", clientSecret: "test", webhookSecret: null, slug: "test",
    privateKeyPem: privateKey.export({ type: "pkcs1", format: "pem" }).toString(),
    apiUrl: server.url.origin, webUrl: server.url.origin,
  });
  try {
    expect(await gh.installationToken(1)).toBe("token-1");
    expect(await gh.installationToken(1)).toBe("token-1");
    expect(await gh.mintCloneToken(1)).toBe("token-2");
    expect(await gh.mintCloneToken(1)).toBe("token-3");
    expect(await gh.installationToken(1)).toBe("token-3");
    expect(minted).toBe(3);
  } finally { server.stop(true); }
});
