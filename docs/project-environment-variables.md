# Readable project environment variables (RAV-15)

Project settings → Environment variables edits Fountain's shared environment
`env_vars`. Values are visible to anyone with project-settings access (currently
the owner). Credentials belong in Secrets. Ravix stores no copy of the values in
its database. Per-user overrides are deferred.

Names use letters, digits and underscores and start with a letter or underscore.
A project can configure 100 entries, with names up to 200 bytes and each UTF-8
value up to 16 KiB. Empty strings are preserved; NUL is rejected. Duplicate rows,
the reserved clone-token name, existing project secret names, and Fountain's
provider-auth aliases are rejected. Provider-auth overrides belong in Secrets
under ADR 0005. The alias list and upstream source are documented in
`Ravix.Projects.EnvironmentVariables`.

MCP `get_project_settings` returns `env_vars`. `update_project_settings` accepts a
string-to-string object: it replaces the entire map, `{}` clears it, and omitting
it preserves it. MCP intentionally replaces unconditionally, without a stale-map check.
Writes are serialized per project. The dialog sends the map it loaded and refuses
a save if Fountain now has a different map; reload settings before retrying. The browser submits rows so duplicate names are detected before
conversion to a map. Errors contain validation codes and explanations, never
values. Phoenix filters `env_vars` parameters, settings and editable-row inspection redact them,
and environment API failures omit response text from logs.

Changing variables clears Fountain's warm-start checkpoint; the next track starts
cold and reruns setup.

A changed map bumps `project.rev` and invalidates the cached environment.
Fountain injects the latest map when a conversation starts. Running conversations
keep their previous values until restarted or rebuilt. Dedicated tracks reference
the same project environment (`Tracks.Sandbox.Store`); no per-track vault refresh
or snapshot copy is required for these readable values.

The adapter uses `Fountain.HTTP.request/4` from SDK 0.6.0, which JSON-encodes the
body and returns the response without an environment schema projection. No SDK
struct workaround is necessary. Provider state remains authoritative; edits made
directly in Fountain do not bump Ravix's project revision.
