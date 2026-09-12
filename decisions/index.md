# Decisions

Architecture Decision Records for Ravix, one per file, numbered in the
order they were opened. Every file carries OKF frontmatter (`type`, `status`,
`adr_status`, `description`, `verified`, `stale_after`); `okf validate .`
checks it and `okf backlinks . <id>` shows what depends on a decision.
`adr_status` is the ADR's own lifecycle (Proposed / Accepted / Partially
accepted / Superseded by NNNN); `status` is the OKF lifecycle derived from it
(draft / stable / deprecated). Gaps in the numbering are ADRs still on open
branches.

## ADRs

| # | Title | ADR status | Verified | Stale after | Description |
|---|-------|------------|----------|-------------|-------------|
| 0001 | [ADR template (copy this when writing a real ADR)](0001-template.md) | Template | no |  | Copy this file to write a new ADR; it fixes the frontmatter, the section shape, and the rule that unbuilt behavior is never described as built. |
| 0002 | [Ravix is an Elixir application: Phoenix and LiveView on Fountain's stack and conventions](0002-elixir-and-liveview.md) | Accepted | no | 2026-12-09 | The Bun server and React SPA are replaced by one Phoenix application with LiveView pages, on Fountain's libraries and its engineering discipline; native previews, the Mac runner and the shared browser are scoped out and return as features later (#11, #12). |
| 0003 | [Ravix runs on more than one instance: `:global` names, a cluster singleton, and a readiness-gated rolling deploy](0003-cluster-and-transparent-deploys.md) | Accepted | yes |  | Two or more instances in one region form an Erlang cluster over Render's discovery DNS; the transcript follower and preview server become `:global` names, the preview reconciler a cluster singleton, the prompt-queue sweep stays on every instance, and rotation is gated on a database-backed /readyz. Horde is deliberately not used; its tripwires are recorded here. |
| 0004 | [Telemetry: OpenTelemetry traces to Honeycomb, product analytics and feature flags in PostHog](0004-telemetry-honeycomb-and-posthog.md) | Accepted | no | 2026-12-11 | Performance is answered with OpenTelemetry traces exported to Honeycomb over OTLP/HTTP, through one `Ravix.Trace` door that sanitises attributes, suppresses recurring background work, and carries context across this application's many process hops. Product analytics and feature flags go to PostHog server-side only, with no browser SDK, no autocapture and no session replay -- neither of those two is built yet. |
