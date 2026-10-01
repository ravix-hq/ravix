# RAV-133 / RAV-134 / RAV-135 screenshots

Playwright captures from the browser harness (`python3 browser/server.py`:
production build + provider mock), taken by `shots.mjs` against `main` at
32bc83cf for `before/` and against `ravix/rav-133-connect-agent-step` for
`after/`. Viewport 1180×860 at 2×, login @connectstep.

- `dialog-token-dark.png`, `dialog-token-light.png`: Add a repository with
  Claude Code not connected and a token pasted, in the Ravix and Daylight themes.
- `dialog-empty-submit.png`: Connect pressed with the field empty. Before:
  Chrome's native "Please fill in this field." bubble, which Playwright does
  not capture (it is browser chrome, not page content); the field is `required`.
  After: the page's own sentence beside the field.
- `dialog-connecting.png`: the token being checked (the mock holds the answer
  for 6s). Before: "Updating agent connection…" inserted above the tabs, the
  token wiped, the full-width button dimmed. After: the button says
  Connecting… in the same box, the token stays, nothing is inserted.
- `dialog-connected.png`: the dialog once Claude Code is connected.
- `welcome-agent.png`, `settings-agents.png`: the same panel in the walkthrough
  and in Settings › Agents.
