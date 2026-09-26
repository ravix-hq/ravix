# Read metadata only: never follow an entry's symlink or execute repository code.
import base64
import json
import os
import subprocess
import sys

root, path, names = json.loads(base64.b64decode(sys.argv[1]))
root = os.path.realpath(root)
path = os.path.realpath(path)
if os.path.commonpath([root, path]) != root:
    raise ValueError("directory outside worktree")
if any(name in ("", ".", "..") or "/" in name or "\0" in name for name in names):
    raise ValueError("invalid entry name")
paths = [os.path.join(path, name) for name in names]
env = dict(os.environ, GIT_CEILING_DIRECTORIES=os.path.dirname(root), GIT_OPTIONAL_LOCKS="0")
probe = subprocess.run(
    ["git", "-C", root, "rev-parse", "--show-toplevel"],
    capture_output=True, timeout=5, env=env,
)
ignored = set()
ignore_available = probe.returncode == 0
if ignore_available and paths:
    result = subprocess.run(
        ["git", "-C", root, "check-ignore", "-z", "--stdin"],
        input=b"\0".join(os.fsencode(p) for p in paths) + b"\0",
        capture_output=True, timeout=5, env=env,
    )
    ignore_available = result.returncode in (0, 1)
    if ignore_available:
        ignored = {os.fsdecode(p) for p in result.stdout.split(b"\0") if p}
entries = {}
for name, full in zip(names, paths):
    target = None
    if os.path.islink(full):
        try:
            target = os.readlink(full)
        except OSError:
            pass
    entries[name] = {"ignored": full in ignored, "target": target}
print(json.dumps({"ignore_available": ignore_available, "entries": entries}))
