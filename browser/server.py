#!/usr/bin/env python3
"""Own a production-mode app, provider mocks, and a disposable browser database."""
import os
import json
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
children = []

def stop(*_):
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

def start(args, env):
    process = subprocess.Popen(args, env=env, start_new_session=True)
    children.append(process)
    return process

# Never attach to another developer's server or database.
ports = tuple(int(os.environ.get(key, default)) for key, default in
              (("BROWSER_PORT", "4103"), ("MOCK_PORT", "8893"), ("MOCK_SPRITES_PORT", "8894")))
for port in ports:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", port))

env = dict(os.environ, MIX_ENV="prod", PORT=str(ports[0]), PHX_SERVER="true",
           PUBLIC_URL=f"http://localhost:{ports[0]}", RAVIX_URL=f"http://localhost:{ports[0]}",
           MOCK_PORT=str(ports[1]), MOCK_SPRITES_PORT=str(ports[2]),
           RAVIX_SECRET="browser-test-only-secret-never-used-outside-this-process",
           RAVIX_BROWSER_TEST="1", RAVIX_THREADS_ENABLED="true",
           RAVIX_DEDICATED_OPEN_USER_IDS="00000000-0000-4000-8000-000000009003,00000000-0000-4000-8000-000000009004,"
                                         "00000000-0000-4000-8000-000000009009,00000000-0000-4000-8000-000000009013,"
                                         "00000000-0000-4000-8000-000000009048",
           # ADR 0009's switch, off as in production unless the run asks:
           # `bun run test:browser:workspace-access` turns it on for the
           # specs that need it (workspace-visibility.spec.js,
           # workspace-teams.spec.js, workspace-github.spec.js,
           # workspace-sharing.spec.js, workspace-new-track.spec.js,
           # workspace-scope.spec.js, workspace-attribution.spec.js,
           # settings-frame.spec.js, workspace-settings-pages.spec.js).
           RAVIX_WORKSPACE_ACCESS=os.environ.get("RAVIX_WORKSPACE_ACCESS", "false"))
# Only a generated database name is ever created/dropped. Credentials can differ locally.
base = os.environ.get("BROWSER_DATABASE_SERVER", "postgres://postgres:postgres@localhost:5432")
if "/" in base.split("://", 1)[-1]:
    raise SystemExit("BROWSER_DATABASE_SERVER must contain only scheme, credentials, host and port")
env["DATABASE_URL"] = base + "/ravix_browser_" + uuid.uuid4().hex
# Browser fixtures may alter only this harness-owned disposable database.
manifest = ROOT / "tmp" / f"browser-{ports[0]}.json"
manifest.parent.mkdir(exist_ok=True)
manifest.write_text(json.dumps({"database": env["DATABASE_URL"].rsplit("/", 1)[1]}))
created = False
with tempfile.TemporaryDirectory(prefix="ravix-browser-") as tmp:
    env["MOCK_KEY_PATH"] = str(Path(tmp) / "key.pem")
    try:
        mock = start(["bun", "mock/server.ts"], env)
        for _ in range(100):
            if mock.poll() is not None:
                raise SystemExit("Provider mock exited before becoming ready")
            if Path(env["MOCK_KEY_PATH"]).exists():
                break
            time.sleep(0.1)
        else:
            raise SystemExit("Provider mock never became ready")
        subprocess.run(["mix", "ecto.create"], env=env, check=True)
        created = True
        subprocess.run(["mix", "ecto.migrate"], env=env, check=True)
        # These mock identities exercise dedicated threads and private tracks.
        # Seed stable app IDs; authentication still goes through GitHub.
        subprocess.run(["psql", env["DATABASE_URL"], "-X", "-v", "ON_ERROR_STOP=1", "-c",
                        "INSERT INTO ravix.users (id, github_id, login, created_at, last_seen_at) "
                        "VALUES ('00000000-0000-4000-8000-000000009003', '9003', "
                        "'threadruntime', NOW(), NOW()), "
                        "('00000000-0000-4000-8000-000000009004', '9004', "
                        "'privacycreator', NOW(), NOW()), "
                        "('00000000-0000-4000-8000-000000009009', '9009', "
                        "'workspacecreator', NOW(), NOW()), "
                        "('00000000-0000-4000-8000-000000009013', '9013', "
                        "'sharecreator', NOW(), NOW()), "
                        "('00000000-0000-4000-8000-000000009048', '9048', "
                        "'newtrackfit', NOW(), NOW())"], check=True)
        app = start(["python3", "scripts/dev-mock.py"], env)
        while app.poll() is None and mock.poll() is None:
            time.sleep(0.2)
        raise SystemExit("Browser server or provider mock exited unexpectedly")
    finally:
        for process in reversed(children):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        manifest.unlink(missing_ok=True)
        if created:
            subprocess.run(["mix", "ecto.drop", "--force"], env=env, check=True)
