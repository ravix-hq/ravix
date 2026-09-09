---
name: ravix-elixir
description: Implement or review Ravix Elixir contexts, Phoenix LiveViews, and OTP lifecycle changes. Use when changing authorization, persistence, asynchronous work, provider integration, or preview behavior in this project.
---

Read AGENTS.md and the relevant context before editing. Ravix is one OTP
application, not Fountain's umbrella. Use Fountain as a reference for scoped
ownership, tagged context results, supervision, and sandbox tests only where the
pattern fits the current code.

Keep effects in their existing boundaries. The web layer calls contexts with
the authenticated user; contexts establish project/track access before provider
calls or `_unsafe_*` helpers. Public errors pass through `RavixWeb.Error`.
Changing a context's result shape requires updating its typespec, callers, and
boundary tests together.

For LiveView work, preserve revocation checks on events, PubSub messages, URL
patches, and async results. Use `start_async` for long work and scope the result
before applying it. Do not capture an entire socket in a task. Preserve entered
text and attachments on failure. Consider duplicate submissions and stale
results, not only the successful click.

For OTP changes, identify the owner, supervisor, shutdown signal, and outstanding
callers. A load that is invalidated or reset must still settle its waiters; an old
result must not overwrite a new generation. Use Registry/DynamicSupervisor for
per-track lifecycles and the existing TaskSupervisor for unlinked work. Verify
crash, cancellation, and teardown using messages/monitors rather than sleeps.

For Ecto changes, preserve the `ravix` schema prefix and real changesets. Do not
assume legacy `public` tables are an imported dataset. Database constraints own
uniqueness; context checks supply useful errors. Test both authorized and denied
callers with persisted fixtures.

Preview work must preserve generation checks, session-bound single-use grants,
streaming/backpressure, and host separation. Inspect tests for the HTTP gateway
and actual Sprites tunnel before altering headers or stream ownership.

Use compiler warnings, strict Credo, Dialyzer, and Sobelow as design feedback.
Keep tagged results and finite atoms at provider boundaries. New suppressions
need a specific documented false positive and behavior evidence. Run focused
regressions followed by `mix precommit`; use the repository testing skill when
working through coverage gaps.
