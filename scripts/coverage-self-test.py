#!/usr/bin/env python3
"""Exercise actual coverage exit codes in throwaway projects, never edit the worktree."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def run(args, cwd):
    return subprocess.run(args, cwd=cwd, env=dict(os.environ, MIX_ENV="test"),
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

def expect(result, success, evidence):
    if (result.returncode == 0) != success or evidence not in result.stdout:
        print(result.stdout)
        raise SystemExit(f"Guard self-test failed: expected success={success}, evidence={evidence!r}")

with tempfile.TemporaryDirectory(prefix="ravix-coverage-") as tmp:
    root = Path(tmp)
    for path in ("lib/ravix", "test/support"):
        (root / path).mkdir(parents=True)
    shutil.copy(ROOT / "test/support/coverage.ex", root / "test/support/coverage.ex")
    (root / "mix.exs").write_text('''defmodule Probe.MixProject do
  use Mix.Project
  def project do
    [app: :coverage_probe, version: "0.1.0", elixirc_paths: ["lib", "test/support"],
     deps: [{:jason, path: "JASON"}],
     test_coverage: [tool: Ravix.Coverage, ignore_modules: [],
       summary: [threshold: String.to_integer(System.get_env("PROBE_TOTAL", "0"))],
       groups: [{(if System.get_env("PROBE_GROUP") == "workspace", do: :workspace, else: :server),
                 String.to_integer(System.get_env("PROBE_FLOOR", "0"))}]]]
  end
end
'''.replace("JASON", str(ROOT / "deps/jason")))
    (root / "lib/ravix/probe.ex").write_text('''defmodule Ravix.Probe do
  def covered, do: :ok
  def missed, do: :missed
end
''')
    (root / "test/test_helper.exs").write_text("ExUnit.start()\n")
    (root / "test/probe_test.exs").write_text('''defmodule ProbeTest do
  use ExUnit.Case
  test "a passing assertion does not imply sufficient coverage" do
    assert Ravix.Probe.covered() == :ok
  end
end
''')
    expect(run(["mix", "deps.get"], root), True, "")
    expect(run(["mix", "test", "--cover"], root), True, "1 test, 0 failures")
    os.environ["PROBE_FLOOR"] = "100"
    expect(run(["mix", "test", "--cover"], root), False, "Coverage group floor not met")
    os.environ["PROBE_FLOOR"] = "0"
    os.environ["PROBE_GROUP"] = "workspace"
    expect(run(["mix", "test", "--cover"], root), False, "Coverage group floor not met")
    os.environ["PROBE_GROUP"] = "server"
    os.environ["PROBE_TOTAL"] = "100"
    expect(run(["mix", "test", "--cover"], root), False, "Coverage test failed")
    print("Elixir guard rejects low groups, empty groups, and low production totals.")

with tempfile.TemporaryDirectory(prefix="ravix-hook-coverage-") as tmp:
    root = Path(tmp)
    shutil.copytree(ROOT / "assets/js", root / "assets/js")
    shutil.copytree(ROOT / "assets/test", root / "assets/test")
    # Metadata tests exercise this repository, independently from hook instrumentation.
    (root / "assets/test/repository.test.js").unlink()
    shutil.copy(ROOT / "bunfig.toml", root / "bunfig.toml")
    (root / "node_modules").symlink_to(ROOT / "node_modules", target_is_directory=True)
    expect(run(["bun", "test"], root), True, "0 fail")
    (root / "assets/js/hooks/untested.js").write_text("export function untestedHook() { return 'must be measured'; }\n")
    expect(run(["bun", "test"], root), False, "untested.js")
    print("Hook guard rejects a new untested hook even when all assertions pass.")
