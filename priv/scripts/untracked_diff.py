# Untracked files as "new file" diffs. Read-only: nothing here writes the index or the tree.
# Bounded by file count, per-file size, total output and a deadline; whatever is cut is reported.
import base64
import json
import os
import subprocess
import sys
import time

root, max_files, max_file_bytes, max_total_bytes, budget = json.loads(base64.b64decode(sys.argv[1]))
root = os.path.realpath(root)
deadline = time.monotonic() + budget
env = dict(os.environ, GIT_CEILING_DIRECTORIES=os.path.dirname(root), GIT_OPTIONAL_LOCKS="0")


def left():
    return max(deadline - time.monotonic(), 0.1)


def quote(path):
    # Git's own header quoting, so a path Git would quote parses the same way.
    raw = os.fsencode(path)
    if all(32 <= b < 127 and b not in (34, 92) for b in raw):
        return path
    escapes = {9: "\\t", 10: "\\n", 13: "\\r", 34: '\\"', 92: "\\\\"}
    body = "".join(
        escapes.get(b) or (chr(b) if 32 <= b < 127 else "\\%03o" % b) for b in raw
    )
    return '"' + body + '"'


listed = subprocess.run(
    ["git", "-C", root, "ls-files", "--others", "--exclude-standard", "-z"],
    capture_output=True, timeout=left(), env=env,
)
if listed.returncode != 0:
    print(json.dumps({"available": False}))
    sys.exit(0)

paths = [os.fsdecode(p) for p in listed.stdout.split(b"\0") if p and not p.endswith(b"/")]
paths.sort()
truncated = len(paths) > max_files
paths = paths[:max_files]
chunks = []
large = []
total = 0

for path in paths:
    if time.monotonic() >= deadline:
        truncated = True
        break
    full = os.path.join(root, path)
    try:
        size = os.lstat(full).st_size
    except OSError:
        continue
    if size > max_file_bytes:
        a, b = quote("a/" + path), quote("b/" + path)
        text = "diff --git %s %s\nnew file mode 100644\n" % (a, b)
        large.append(path)
    else:
        try:
            ran = subprocess.run(
                ["git", "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv",
                 "--", "/dev/null", path],
                cwd=root, capture_output=True, timeout=left(), env=env,
            )
        except subprocess.TimeoutExpired:
            truncated = True
            break
        # 1 is "there are differences", which a new file always has.
        if ran.returncode not in (0, 1):
            continue
        text = ran.stdout.decode("utf-8", "replace")
    if total + len(text) > max_total_bytes:
        truncated = True
        break
    total += len(text)
    chunks.append(text)

print(json.dumps({"available": True, "diff": "".join(chunks), "large": large, "truncated": truncated}))
