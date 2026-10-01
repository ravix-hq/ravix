# RAV-127 screenshots

Sidebar sections before and after they belong to a workspace, captured by
`rav127-screenshots.spec.js` on the local browser harness
(`RAVIX_WORKSPACE_ACCESS=true`, 1280x900, `#yard` only).

Setup: one person, two workspaces (personal `scopeowner`, team `Acme`),
"Client work" created in the personal workspace holding "Billing app",
then "Acme backlog" created in Acme.

| | before (origin/main cbc8bab1) | after (ravix/scope-sections-to-person-workspace-colum) |
|---|---|---|
| 1 personal, section made | `before/1-personal-with-section.png` | `after/1-personal-with-section.png` |
| 2 Acme, nothing made there yet | `before/2-acme-before-own-section.png` (empty "Client work" leaks in) | `after/2-acme-before-own-section.png` |
| 3 Acme, own section made | `before/3-acme-with-own-section.png` | `after/3-acme-with-own-section.png` (empty, still shown) |
| 4 personal again | `before/4-personal-again.png` ("Acme backlog" leaks in) | `after/4-personal-again.png` |
