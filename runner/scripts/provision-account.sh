#!/bin/bash
# Local setup/recheck; invoke with sudo from the SDK-provisioning account.
# No account password, GitHub token or personal configuration is copied.
set -euo pipefail
umask 077

runner_account="${1:-switchyard}"
setup_mode="${2:-install}"
build_id="${3:-}"
if [[ ( "$#" -gt 2 && "$setup_mode" != --check-ios-build && "$setup_mode" != --reset-target ) || "$#" -gt 3 || ( "$setup_mode" != --reset-target && "$setup_mode" != --pair-runner && "$setup_mode" != --serve-runner && "$setup_mode" != install && "$setup_mode" != --archive-runtime && "$setup_mode" != --check-ios-build && "$setup_mode" != --check && "$setup_mode" != --build-ios-hello && "$setup_mode" != --build-hello && "$setup_mode" != --run-hello && "$setup_mode" != --preview-ios-hello && "$setup_mode" != --preview-hello ) ]]; then
  echo 'Usage: provision-account.sh [account] [--reset-target TARGET_UUID | --pair-runner | --serve-runner | --archive-runtime | --check-ios-build BUILD_UUID | --check | --build-hello | --build-ios-hello | --run-hello | --preview-hello | --preview-ios-hello]' >&2; exit 1
fi
if [[ ( "$setup_mode" == --check-ios-build || "$setup_mode" == --reset-target ) && ! "$build_id" =~ ^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$ ]]; then
  echo 'Supply the explicit build or target UUID from its report.' >&2; exit 1
fi
if [[ ! "$runner_account" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  echo 'Choose a standard macOS account name.' >&2; exit 1
fi
if [[ "${EUID}" != 0 || -z "${SUDO_USER:-}" || "$SUDO_USER" == root ]]; then
  echo 'Run with sudo from the account where the SDK tools were installed.' >&2; exit 1
fi
runner_uid="$(id -u "$runner_account")"
runner_gid="$(id -g "$runner_account")"
if [[ "$runner_uid" -lt 501 || "$runner_account" == "$SUDO_USER" ]]; then
  echo 'Choose a separate standard user account.' >&2; exit 1
fi
if id -Gn "$runner_account" | tr ' ' '\n' | /usr/bin/grep -qx admin; then
  echo 'The runner account must be a standard user, not an administrator.' >&2; exit 1
fi
runner_home="$(dscl . -read "/Users/$runner_account" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
source_home="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
if [[ "$runner_home" != "/Users/$runner_account" || ! "$source_home" =~ ^/Users/[^/]+$ ]]; then
  echo 'This setup expects ordinary /Users/<account> home directories.' >&2; exit 1
fi
runner_source="$(cd "$(dirname "$0")/.." && pwd -P)"
sdk_source="$source_home/Library/Android/sdk"
companion_source="$source_home/.local/share/switchyard/tools/idb-companion/1.1.8"
if [[ "$setup_mode" == install ]]; then
  for executable in "$source_home/.bun/bin/bun" "$source_home/.local/bin/uv" "$sdk_source/platform-tools/adb" "$sdk_source/cmdline-tools/latest/bin/avdmanager" "$companion_source/bin/idb_companion" /opt/homebrew/bin/node /opt/homebrew/bin/scrcpy /opt/homebrew/bin/pod; do
    [[ -x "$executable" ]] || { echo "Missing prerequisite: $executable" >&2; exit 1; }
  done
fi
[[ -f "$runner_source/index.ts" ]] || { echo 'Runner source missing.' >&2; exit 1; }
[[ ! -L "$runner_home" ]] || { echo 'Runner home must not be a symlink.' >&2; exit 1; }
if [[ ! -d "$runner_home" ]]; then
  [[ "$setup_mode" == install ]] || { echo 'Runner home is missing; complete installation first.' >&2; exit 1; }
  /usr/sbin/createhomedir -c -u "$runner_account"
fi
[[ "$(stat -f %u "$runner_home")" == "$runner_uid" ]] || { echo 'Unexpected home owner.' >&2; exit 1; }

# Stage only tool binaries, SDK packages and runner source. Root reads the source
# account; every write inside the destination home happens as the standard user.
stage="$(mktemp -d /private/tmp/switchyard-provision.XXXXXXXX)"
trap '/bin/rm -rf -- "$stage"' EXIT
/usr/bin/ditto "$runner_source" "$stage/runner"
/bin/mkdir "$stage/shared"
/usr/bin/install -m 600 "$runner_source/../shared/native-preview.ts" "$stage/shared/native-preview.ts"
/usr/bin/install -m 600 "$runner_source/../shared/runners.ts" "$stage/shared/runners.ts"
if [[ "$setup_mode" == --pair-runner ]]; then
  runner_config=/private/tmp/switchyard-runner.json
  [[ -f "$runner_config" && ! -L "$runner_config" && "$(stat -f %u "$runner_config")" == "$(id -u "$SUDO_USER")" ]] || {
    echo 'Prepare /private/tmp/switchyard-runner.json with the verified builds first.' >&2; exit 1
  }
  /usr/bin/install -m 600 "$runner_config" "$stage/runner-config.json"
  echo 'Paste the runner pairing code from Switchyard:'
  IFS= read -r pairing_code </dev/tty
  [[ "$pairing_code" =~ ^[a-zA-Z0-9_-]{43}$ ]] || { echo 'Invalid pairing code.' >&2; exit 1; }
  printf '%s\n' "$pairing_code" > "$stage/pairing.txt"
  unset pairing_code
fi
if [[ "$setup_mode" == --run-hello || "$setup_mode" == --preview-ios-hello || "$setup_mode" == --preview-hello ]]; then
  runtime_config=/private/tmp/switchyard-hello-runtime.json
  if [[ "$setup_mode" == --preview-hello ]]; then runtime_config=/private/tmp/switchyard-hello-preview.json; fi
  if [[ "$setup_mode" == --preview-ios-hello ]]; then runtime_config=/private/tmp/switchyard-hello-ios-preview.json; fi
  [[ -f "$runtime_config" && ! -L "$runtime_config" && "$(stat -f %u "$runtime_config")" == "$(id -u "$SUDO_USER")" ]] || {
    echo 'Prepare the Hello runtime config with the explicit build path and artifact digest first.' >&2; exit 1
  }
  /usr/bin/install -m 600 "$runtime_config" "$stage/runtime.json"
fi
if [[ "$setup_mode" == --build-hello || "$setup_mode" == --build-ios-hello ]]; then
  fixture_snapshot=/private/tmp/switchyard-hello-source.json
  [[ -f "$fixture_snapshot" && ! -L "$fixture_snapshot" && "$(stat -f %u "$fixture_snapshot")" == "$(id -u "$SUDO_USER")" ]] || {
    echo 'Prepare the Hello World source snapshot as the provisioning account first.' >&2; exit 1
  }
  /usr/bin/install -m 600 "$fixture_snapshot" "$stage/source.json"
fi
if [[ "$setup_mode" == install ]]; then
  /bin/mkdir "$stage/tools"
  /usr/bin/ditto "$sdk_source" "$stage/sdk"
  /usr/bin/ditto "$companion_source" "$stage/companion"
  /usr/bin/install -m 755 "$source_home/.bun/bin/bun" "$stage/tools/bun"
  /usr/bin/install -m 755 "$source_home/.local/bin/uv" "$stage/tools/uv"
fi
/usr/sbin/chown -R "$runner_uid:$runner_gid" "$stage"

# An empty environment excludes the invoking account's credentials and overrides.
/usr/bin/sudo -u "$runner_account" /usr/bin/env -i \
  HOME="$runner_home" USER="$runner_account" LOGNAME="$runner_account" \
  PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 \
  /bin/bash -s -- "$stage" "$runner_home" "$setup_mode" "$build_id" <<'RUNNER_SETUP'
set -euo pipefail
umask 077
stage="$1"
runner_home="$2"
setup_mode="$3"
build_id="$4"
cd "$runner_home"
local_bin="$runner_home/.local/bin"
runtime="$runner_home/.local/share/switchyard"
if [[ "$setup_mode" == --reset-target ]]; then
  exec "$local_bin/bun" "$stage/runner/index.ts" reset-target "$USER" "$build_id"
fi
if [[ "$setup_mode" == --pair-runner ]]; then
  exec "$local_bin/bun" "$stage/runner/index.ts" register "$stage/runner-config.json" "$stage/pairing.txt"
fi
if [[ "$setup_mode" == --serve-runner ]]; then
  exec "$local_bin/bun" "$stage/runner/index.ts" serve "$runtime/managed/config.json"
fi
if [[ "$setup_mode" == --archive-runtime ]]; then
  exec "$local_bin/bun" "$stage/runner/archive-runtime.ts" "$USER"
fi
if [[ "$setup_mode" == --check-ios-build ]]; then
  exec "$local_bin/bun" "$stage/runner/ios-build-diagnostic.ts" "$USER" "$build_id"
fi
if [[ "$setup_mode" == --run-hello || "$setup_mode" == --preview-ios-hello || "$setup_mode" == --preview-hello ]]; then
  [[ -x "$local_bin/bun" && -x "$local_bin/switchyard-runner" ]] || {
    echo 'Runner installation is missing; complete installation first.' >&2; exit 1
  }
  export PATH="$local_bin:$PATH"
  runtime_command=runtime-experiment
  if [[ "$setup_mode" == --preview-hello || "$setup_mode" == --preview-ios-hello ]]; then runtime_command=preview-experiment; fi
  exec "$local_bin/bun" "$stage/runner/index.ts" "$runtime_command" "$stage/runtime.json"
fi
if [[ "$setup_mode" == --build-hello || "$setup_mode" == --build-ios-hello ]]; then
  [[ -x "$local_bin/bun" && -x "$local_bin/switchyard-runner" ]] || {
    echo 'Runner installation is missing; complete installation first.' >&2; exit 1
  }
  export PATH="$local_bin:$PATH"
  "$local_bin/bun" -e '
    const [stage, home, account, mode] = process.argv.slice(1);
    await Bun.write(stage + "/build.json", JSON.stringify({ snapshot: stage + "/source.json", stateDirectory: home + "/.local/share/switchyard/builds", expectedAccount: account, platform: mode === "--build-ios-hello" ? "ios" : "android" }));
  ' "$stage" "$runner_home" "$USER" "$setup_mode"
  # Execute the staged runner as the standard account; do not replace the
  # installed adapters or compile from the authoritative source checkout.
  exec "$local_bin/bun" "$stage/runner/index.ts" build-experiment "$stage/build.json"
fi
if [[ "$setup_mode" == --check ]]; then
  [[ -x "$local_bin/switchyard-runner" && -f "$runtime/runner/index.ts" ]] || {
    echo 'Runner installation is missing; complete installation first.' >&2; exit 1
  }
  # Refresh only the read-only diagnostic module. Leave adapters and installed
  # binaries intact so this recheck does not change active device behavior.
  install -m 600 "$stage/runner/doctor.ts" "$runtime/runner/doctor.ts"
else
if [[ -e "$runtime" ]]; then
  echo "Runner installation already exists at $runtime; refusing to replace it." >&2
  exit 1
fi
mkdir -p "$local_bin" "$runtime" "$runner_home/Library/Android"
ditto "$stage/sdk" "$runner_home/Library/Android/sdk"
ditto "$stage/companion" "$runtime/tools/idb-companion/1.1.8"
ditto "$stage/runner" "$runtime/runner"
ditto "$stage/shared" "$runtime/shared"
install -m 755 "$stage/tools/bun" "$local_bin/bun"
install -m 755 "$stage/tools/uv" "$local_bin/uv"
ln -s "$runtime/tools/idb-companion/1.1.8/bin/idb_companion" "$local_bin/idb_companion"
export PATH="$local_bin:$PATH"
uv tool install --python 3.12 'fb-idb==1.5.2'
cat > "$local_bin/switchyard-runner" <<'LAUNCHER'
#!/bin/sh
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
exec "$HOME/.local/bin/bun" "$HOME/.local/share/switchyard/runner/index.ts" "$@"
LAUNCHER
chmod 700 "$local_bin/switchyard-runner"
fi
echo 'Checking runner tools (emulator probes run sequentially, up to 60 seconds each)...'
check_status=0
"$local_bin/switchyard-runner" doctor > "$runtime/doctor.json" || check_status=$?
"$local_bin/bun" -e '
  const report = await Bun.file(process.argv[1]).json();
  const emulatorChecks = Object.fromEntries(["emulator", "acceleration", "androidProfiles"].map(name => [name, report.tools[name]]));
  console.log(JSON.stringify({ android: report.android.blockers, ios: report.ios.blockers, emulatorChecks }, null, 2));
' "$runtime/doctor.json" || true
if [[ "$check_status" != 0 ]]; then
  echo "Full report: $runtime/doctor.json. Tools retained; no reinstall is needed." >&2
  exit 1
fi
echo "Readiness checks passed. Inventory: $runtime/doctor.json"
RUNNER_SETUP
