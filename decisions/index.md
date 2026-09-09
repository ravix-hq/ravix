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
