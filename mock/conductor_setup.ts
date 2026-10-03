/** Shared Conductor setup fixtures for manual import review in the mock app. */
export function conductorSetupFile(path: string): string | undefined {
  const files: Record<string, string> = {
    ".conductor/settings.toml": `file_include_globs = ".env*"
[scripts]
setup = "npm ci"
archive = "./scripts/archive-workspace.sh"
run_mode = "nonconcurrent"
[scripts.run.web]
command = "npm run dev -- --host 127.0.0.1 --port $PORT --strictPort"
available_in = ["cloud"]
default = true
[scripts.run.tests]
command = "npm test -- --watch"
[scripts.run.mac]
command = "npm run dev -- --port $CONDUCTOR_PORT"
available_in = ["local"]
`,
    "conductor.json": JSON.stringify({ scripts: { setup: "legacy install", run: "legacy run" } }),
    ".worktreeinclude": "# Required local configuration\n.env.local\nconfig/local.json\ncerts/**\n!certs/public/**\n",
  };
  return files[path];
}
