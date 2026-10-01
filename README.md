# RAV-128 screenshots

Playwright captures from the browser harness with `RAVIX_WORKSPACE_ACCESS=true`,
taken by `capture.spec.js` (copied into `browser/` and run against `main` at
cbc8bab1 for `before/` and against `ravix/rav-128-label-projects-by-workspace-inst` for `after/`).

- `team-project-member.png`, `team-track-member.png`: @teammate, a non-creator
  member of the "Acme Robotics" team workspace, on the project "ravix" that
  @teamowner created there.
- `team-project-creator.png`, `team-track-creator.png`: @teamowner, the creator.
- `legacy-project-member.png`: @teammate on "ravix-legacy", a legacy project
  (no workspace) @teamowner shared with them.
