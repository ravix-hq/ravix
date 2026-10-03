# Deprecated Browser Smoke Tests

The Playwright specs in this directory are deprecated and disabled by default.
Many of them assert literal strings, fixed copy, visual polish, or specific UI
component structure, so they should not drive routine feature work.

Use focused ExUnit and Happy DOM hook tests for regression coverage instead. If
a real browser check is explicitly needed, run `bun run test:browser:deprecated`
or `bun run test:browser:workspace-access:deprecated` and keep changes to this
suite minimal.
