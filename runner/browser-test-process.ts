import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

/** Run the actual service in Node, as it runs on a Sprite. */
export async function startTestBrowser({ directory, token, executablePath }: { directory: string; token: string; executablePath: string }) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(join(directory, "token"), token, { mode: 0o600 });
  const child = Bun.spawn(["node", join(import.meta.dir, "scripts/browser-worker.cjs")], {
    env: { ...process.env, SWITCHYARD_BROWSER_DIR: directory, SWITCHYARD_CHROMIUM: executablePath, PORT: "0" }, stdout: "pipe", stderr: "pipe",
  });
  const reader = child.stdout.getReader(), errors = new Response(child.stderr).text();
  const timer = setTimeout(() => child.kill("SIGKILL"), 30000);
  try {
    let output = "";
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) throw Error(`Browser worker did not start: ${await errors}`);
      output += new TextDecoder().decode(chunk.value);
      const match = /listening on loopback:(\d+)/.exec(output);
      if (match) {
        let closing = false;
        return { port: Number(match[1]), close: async () => { if (!closing) { closing = true; child.kill("SIGTERM"); } await child.exited; } };
      }
    }
  } catch (error) { child.kill("SIGKILL"); await child.exited; throw error; }
  finally { clearTimeout(timer); reader.releaseLock(); }
}
