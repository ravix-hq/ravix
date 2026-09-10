#!/usr/bin/env python3
"""Run a checksum-pinned Gitleaks binary without an action license or credentials."""
import hashlib
import io
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = "8.30.1"
CHECKSUMS = {
    ("Darwin", "arm64"): ("darwin_arm64", "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"),
    ("Linux", "x86_64"): ("linux_x64", "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"),
    ("Darwin", "x86_64"): ("darwin_x64", "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"),
    ("Linux", "aarch64"): ("linux_arm64", "e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080"),
}

def main():
    target, expected = CHECKSUMS[(platform.system(), platform.machine())]
    url = f"https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/gitleaks_{VERSION}_{target}.tar.gz"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit("Gitleaks archive checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="ravix-gitleaks-") as tmp:
        binary = Path(tmp) / "gitleaks"
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            binary.write_bytes(archive.extractfile("gitleaks").read())
        binary.chmod(0o700)
        if sys.argv[1:] == ["self-test"]:
            fixture = Path(tmp) / "fixture"
            fixture.mkdir()
            command = [str(binary), "dir", str(fixture), "--redact", "--no-banner"]
            clean = subprocess.run(command, capture_output=True, text=True)
            if clean.returncode != 0:
                raise SystemExit("Secret scanner rejected an empty fixture")
            (fixture / "leak.env").write_text("GITHUB_TOKEN=" + "ghp_" + "aB7k9L2m" * 5 + "\n")
            leaking = subprocess.run(command, capture_output=True, text=True)
            if leaking.returncode != 1 or "leaks found" not in leaking.stderr:
                raise SystemExit("Secret scanner failed to reject the synthetic credential")
            print("Secret scanner accepts a clean fixture and rejects a synthetic credential.")
            return 0
        # All findings stay redacted, including local runs and self-test failures.
        return subprocess.call([str(binary), *sys.argv[1:], "--redact", "--no-banner"])

if __name__ == "__main__":
    sys.exit(main())
