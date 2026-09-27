# Owner-run Fountain sandbox verification

This is ADR 0006's live enablement gate, not an automated production test.
Agents have **not run it against real Fountain**. The project owner must run it
with their own Fountain token and a disposable test project/account context.
It creates a uniquely named environment, three vaults, two agents, conversations
and sandboxes. These are disposable; the existing inference credential set is
referenced, never changed. Both runtimes spend the owner's connected subscriptions.
No repository or production track is used.

Requires Python 3.10+, an HTTPS Fountain origin and a credential set with both
Claude and Codex usable. Choose currently available provider-prefixed models
from that Fountain's catalog. Keep the token out of arguments and shell history:

```sh
python3 scripts/fountain-sandbox-check.py --dry-run
read -rs -p 'Fountain test token: ' FOUNTAIN_CHECK_TOKEN
export FOUNTAIN_CHECK_TOKEN
python3 scripts/fountain-sandbox-check.py \
  --base-url https://YOUR-FOUNTAIN-HOST \
  --credential-set-id YOUR-EXISTING-OWNER-SET \
  --claude-model YOUR-CLAUDE-MODEL \
  --codex-model YOUR-CODEX-MODEL \
  --home-runtime claude
unset FOUNTAIN_CHECK_TOKEN
```

Repeat with `--home-runtime codex` for the reverse guest direction. The script
reads only `FOUNTAIN_CHECK_TOKEN` (and optionally `FOUNTAIN_CHECK_URL`), not any
agent runtime's ambient Fountain credentials. `--dry-run` reads no token and
makes no requests. Redirects are refused to avoid forwarding credentials.
`--wait-seconds` defaults to 180 per observed operation; HTTP requests have a
60-second timeout. The script prints a PASS/FAIL table and exits nonzero on any
failed assertion or unconfirmed cleanup. It never prints provider bodies,
request headers, token values or exception tracebacks.

Checks:

1. Two vaults using one home agent produce distinct sandbox ids and different
   marker contents at the same path.
2. The other runtime attaches by sandbox id with the same environment and vault
   and writes to the home disk, without changing the other track's disk.
3. A second home thread sees and extends that same disk.
4. Terminating the guest thread preserves the disk and its contents.
5. DELETE is followed by reads until Fountain reports the sandbox `terminated`
   (it keeps the row and answers 200) or a resource-specific `sandbox_not_found`
   or `sandbox_gone`. A generic route 404 is not proof. The sibling disk remains
   readable. An accepted DELETE alone is not completion. Marker files live under
   `/home/sprite`, the only root Fountain's file API reads.
6. A create acknowledgement is deliberately discarded, then sandboxes and
   conversations are listed to identify exactly one allocation by home identity
   and the unique channel. No second create is sent. Missing identity/channel
   fields, ambiguous matches or a real unknown response that cannot be reconciled
   are reported as FAIL. This simulates losing an acknowledgement at the client
   boundary; it does not establish server idempotency or cover every network-loss
   timing. Owner review of the results is required before enabling dedicated opens.

A `finally` cleanup runs on success, assertion failure, HTTP/transport failure,
Ctrl-C and SIGTERM. It terminates known conversations, discovers sandboxes owned
by only this run's agents, deletes and confirms those sandboxes, then deletes
agents, vaults and environment. Unique names are recorded before resource creates
so a lost resource acknowledgement can be reconciled by name. Agent deletion is
also a fallback for an unknown home allocation. Cleanup continues after errors;
unresolved resources/intent names are printed as FAIL for the owner to inspect.
SIGKILL or a machine crash cannot run cleanup. Keep the output, and inspect the
`ravix-check-…` resources if the process is forcibly killed or cleanup fails.
Never rerun a create to resolve an uncertain outcome.

Offline verification (no token or provider connection):

```sh
python3 scripts/fountain-sandbox-check-test.py
mix test test/ravix/fountain_test.exs test/ravix/mock_contract_test.exs
bun test
```

The Bun contract fixture defaults to one active turn **per runtime**, configurable
with `MOCK_RUNTIME_CAPACITY`; its tests exercise two simultaneous same-runtime
turns plus an independent guest turn. The fixture and transport tests are not
evidence that a hosted provider supports the contract. Attach owner-run results
to the B2 PR before rollout; do not enable dedicated-track writers in this phase.
