#!/usr/bin/env python3
"""Run Phoenix against the local mock (start `bun run mock` separately)."""
import os
from pathlib import Path

root = Path(__file__).resolve().parent.parent
os.chdir(root)
port = os.environ.get("PORT", "4000")
mock_port = os.environ.get("MOCK_PORT", "8793")
sprites_port = os.environ.get("MOCK_SPRITES_PORT", "8794")
key = root / "mock/dev-key.pem"
if not key.exists():
    raise SystemExit("Start bun run mock first to generate the development key.")
os.environ.update({
    "PORT": port,
    "PUBLIC_URL": f"http://localhost:{port}",
    "FOUNTAIN_URL": f"http://localhost:{mock_port}",
    "FOUNTAIN_API_KEY": "ftn_mock",
    "SPRITES_TOKEN": "sprites_mock",
    "SPRITES_URL": f"http://localhost:{sprites_port}",
    "PREVIEW_DOMAIN": "preview.localhost",
    "GITHUB_API_URL": f"http://localhost:{mock_port}/gh",
    "GITHUB_WEB_URL": f"http://localhost:{mock_port}/ghweb",
    "GITHUB_APP_ID": "1",
    "GITHUB_APP_SLUG": "ravix-mock",
    "GITHUB_CLIENT_ID": "Iv1.mock",
    "GITHUB_CLIENT_SECRET": "mocksecret",
    "GITHUB_PRIVATE_KEY": key.read_text(),
})
os.execvp("mix", ["mix", "phx.server"])
