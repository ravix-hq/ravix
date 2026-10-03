# Import repository Conductor setup

After adding a repository, open **Project settings → Machine → Import Conductor
setup**. Discover reads the project's configured default branch with Ravix's
GitHub App installation credential. It inspects only `.conductor/settings.toml`,
`conductor.json`, and `.worktreeinclude`; it does not run repository commands.
The project owner can inspect and apply candidates. Every event and discovery
result rechecks ownership and the signed-in session.

Review the displayed commands, choose a setup script and/or one named run script,
then **Apply selected scripts to settings**. Nothing is selected automatically,
even a Conductor default. Apply fills only selected fields in the existing Machine
form. It preserves entered packages, variables, secrets, readiness/stop commands,
and every unselected script. Review the resulting form, then use its ordinary
Save flow. The existing machine rebuild confirmation applies to setup changes;
run defaults are saved through the existing preview context and stop affected
running defaults. Apply itself neither saves nor starts a run script.

TOML is decoded by `toml_elixir`, a maintained TOML 1.0/1.1 parser. TOML takes
precedence over legacy JSON. For Conductor cloud compatibility only, a TOML file
that omits `scripts.setup` can take setup from legacy JSON; legacy run/archive
settings do not override TOML. Invalid higher-precedence files are reported rather
than silently falling back. Each file must be ordinary UTF-8 text, at most 64 KiB.
The importer accepts at most 32 named run scripts and 100 provisioning patterns.

Named run scripts preserve cloud availability, default annotations, arguments
(shell-quoted as literals), and relative `options.cwd`. Local-only scripts remain
visible for review but cannot be applied. Commands mentioning `CONDUCTOR_`
variables require manual editing and cannot be selected: Conductor's
`$CONDUCTOR_PORT` is local-only and its other variables are not provided by Ravix.
Ravix run servers must honor `$PORT`, bind to `127.0.0.1`, and refuse fallback to
another port. The importer does not try to rewrite arbitrary shell programs or
prove they will run in the cloud. Review toolchains, process lifetime and shared
resources before saving.

`.worktreeinclude` takes precedence over `file_include_globs`, including an empty
file. When neither is present, Conductor's `.env*` default is displayed. These
patterns are provisioning suggestions only: negations and globs remain patterns,
not a list of existing files. Ravix does not fetch files from a Mac, resolve globs,
read `.env` values or import repository `environment_variables`. Provision required
configuration and secrets explicitly through Machine settings. Archive scripts,
run-mode settings, automatic run after setup and Spotlight testing are reported
as unsupported; no native runner or archive hook is created. Discovery sees shared
repository files only, not machine-local, user or managed Conductor settings.

The source format follows Conductor's official
[repository schema](https://conductor.build/schemas/settings.repo.schema.json),
[legacy JSON reference](https://conductor.build/docs/reference/conductor-json),
[script reference](https://conductor.build/docs/reference/scripts), and
[file-copy reference](https://conductor.build/docs/reference/worktreeinclude).
