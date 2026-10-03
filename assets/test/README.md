# Deprecated Literal and Cosmetic Tests

Files named `*.deprecated.js` are disabled from the default `bun test` run, and
individual deprecated cases inside otherwise behavioral files use `test.skip`.
They cover exact copy, literal formatting, labels/tooltips, theme or focus-ring
polish, layout sizing, and visual positioning rather than behavior.

Do not update these tests for routine feature work. Prefer focused hook tests
that assert functional outcomes.
