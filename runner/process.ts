import { spawn } from "node:child_process";

export interface CommandOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  signal?: AbortSignal;
  timeoutMs?: number;
  maxBytes?: number;
  input?: string;
  /** Graceful end for bounded capture experiments. Still subject to timeoutMs. */
  interruptAfterMs?: number;
}
export interface CommandResult { code: number; stdout: Buffer; stderr: Buffer }
export type Command = (argv: string[], options?: CommandOptions) => Promise<CommandResult>;

/** No shell, bounded output and lifetime, and termination of the process group.
 * Build scripts are trusted code; this is resource control, not a sandbox. */
export const command: Command = async (argv, options = {}) => {
  if (!argv[0]) throw new Error("Missing executable");
  options.signal?.throwIfAborted();
  const limit = options.maxBytes ?? 1024 * 1024;
  const timeout = options.timeoutMs ?? 15_000;
  if (!Number.isSafeInteger(limit) || limit < 1 || !Number.isSafeInteger(timeout) || timeout < 1) throw new Error("Invalid command limits");
  return new Promise((resolve, reject) => {
    const child = spawn(argv[0]!, argv.slice(1), {
      cwd: options.cwd, env: options.env, stdio: ["pipe", "pipe", "pipe"], detached: process.platform !== "win32",
    });
    child.stdin.on("error", () => {});
    child.stdin.end(options.input);
    const stdout: Buffer[] = [], stderr: Buffer[] = [];
    let bytes = 0, failure: Error | undefined, killTimer: ReturnType<typeof setTimeout> | undefined;
    const kill = (signal: NodeJS.Signals) => {
      try {
        if (child.pid && process.platform !== "win32") process.kill(-child.pid, signal);
        else child.kill(signal);
      } catch { /* Already exited. */ }
    };
    const stop = (error: Error) => {
      if (failure) return;
      failure = error;
      kill("SIGTERM");
      killTimer = setTimeout(() => kill("SIGKILL"), 1000);
    };
    const collect = (chunks: Buffer[]) => (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > limit) stop(new Error(`Command exceeded ${limit} output bytes`));
      else chunks.push(chunk);
    };
    child.stdout.on("data", collect(stdout));
    child.stderr.on("data", collect(stderr));
    const interruptTimer = options.interruptAfterMs ? setTimeout(() => kill("SIGINT"), options.interruptAfterMs) : undefined;
    const timer = setTimeout(() => stop(new Error(`Command exceeded ${timeout} ms`)), timeout);
    const abort = () => stop(new Error("Command cancelled"));
    options.signal?.addEventListener("abort", abort, { once: true });
    if (options.signal?.aborted) abort();
    const cleanup = () => { clearTimeout(timer); if (interruptTimer) clearTimeout(interruptTimer); if (killTimer) clearTimeout(killTimer); options.signal?.removeEventListener("abort", abort); };
    child.once("error", error => { cleanup(); reject(error); });
    child.once("close", code => {
      if (failure) kill("SIGKILL");
      cleanup();
      if (failure) {
        const diagnostic = Buffer.concat([...stderr, ...stdout]).toString("utf8").trim().slice(-2000);
        if (diagnostic) failure.message += `\n${diagnostic}`;
        reject(failure);
      } else resolve({ code: code ?? -1, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr) });
    });
  });
};

export async function checked(run: Command, argv: string[], options?: CommandOptions): Promise<Buffer> {
  const result = await run(argv, options);
  if (result.code !== 0) throw new Error(`${argv[0]} failed (${result.code}): ${result.stderr.toString("utf8").slice(-2000)}`);
  return result.stdout;
}
