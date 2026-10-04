# Conductor UI Reference Capture

> Historical notes from the 2026-10-03 capture session; checklist items describe that session, not current implementation status. See [the capture index](README.md) for every image and known capture limitations.

Captured from the local Mac Conductor app on 2026-10-03.

Files:

- `./conductor-current.jpg` - first current-window capture.
- `./conductor-tour/01-current-workstation.jpg` - active workspace with chat, right file panel and terminal dock.
- `./conductor-tour/02-command-palette.jpg` - command/search palette.
- `./conductor-tour/06-home-section.jpg` - workspace home/list view.
- `./conductor-tour/08-right-changes.jpg` - active thread with file panel.
- `./conductor-tour/09-right-checks.jpg` - active thread with changes/empty panel.
- `./conductor-tour/10-right-review.jpg` - active thread with checks/review-ish panel.
- `./conductor-tour/11-terminal-panel.jpg` - bottom terminal dock state.
- `./conductor-corrected-details/02-conductor-model-menu.jpg` - clean composer model picker with model search, model rows, effort row, fast toggle, edit/cycle-effort affordance, shortcuts, and selection checkmark.
- `./conductor-corrected-details/03-conductor-model-menu-expanded.jpg` - same model picker with Fast enabled, useful for toggle styling.
- `./conductor-corrected-details/04-new-thread-opened.jpg` - tab-strip plus menu with `Chat` and `Browser` rows.
- `./conductor-detail-pass/11-settings-open.jpg` - Settings > General.
- `./conductor-detail-pass/13-settings-section-2.jpg` - Settings > Appearance.
- `./conductor-detail-pass/14-settings-section-3.jpg` - Settings > Default models.
- `./conductor-detail-pass/15-settings-section-4.jpg` - Settings > Ports.
- `./conductor-corrected-details/08-terminal-add-tab-menu.jpg` - terminal dock layout; does not show the add-tab menu.
- `./conductor-settings-applescript/03-general.jpg` - current Settings > General.
- `./conductor-settings-applescript/04-account.jpg` - Settings > Account.
- `./conductor-settings-applescript/05-appearance.jpg` - Settings > Appearance.
- `./conductor-settings-applescript/06-default-models.jpg` - Settings > Default models.
- `./conductor-settings-applescript/07-git.jpg` - Settings > Git.
- `./conductor-settings-applescript/11-agents.jpg` - Settings > Agents.
- `./conductor-settings-applescript/12-prompts.jpg` - Settings > Prompts.
- `./conductor-settings-applescript/13-environment.jpg` - Settings > Environment.
- `./conductor-settings-applescript/14-mcp.jpg` - Settings > MCP.
- `./conductor-settings-applescript/17-repo-detail-1.jpg` - repository Settings > Scripts.
- `./conductor-settings-applescript/18-repo-detail-2.jpg` - repository Settings > Git.
- `./conductor-settings-submenus/01-ports.jpg` - current Settings > Ports.
- `./conductor-settings-submenus/17-environment-add-dialog.jpg` - Environment add variable side sheet.
- `./conductor-settings-submenus/20-mcp-add-server-dialog.jpg` - Add MCP server dialog.
- `./conductor-settings-submenus/22-cloud-history-expanded.jpg` - Cloud computer build history expanded.
- `./conductor-settings-submenus/24-cloud-repository-picker.jpg` - Cloud computer repository picker.
- `./conductor-settings-submenus/27-repo-git-default-branch-menu.jpg` - repository Git default branch control.

Design observations to copy into Ravix:

- Rail: very quiet, flat, light-gray selected rows; no dominant primary create row.
- Row rhythm: 32-36px rows, low-contrast icons, text aligned on one vertical grid.
- Home: centered content column with generous whitespace, table-like rows, no card pileup.
- Chat: central column is wide and calm; transcript entries breathe vertically.
- Composer: large rounded rectangle anchored at bottom, subtle border, almost no chrome.
- Header/tabs: small text tabs, thin active underline, minimal button treatment.
- Right panel: tabs are text-first and flat; empty states are centered and sparse.
- Command palette: wide floating sheet, soft shadow, low-contrast filter tabs, grouped rows.
- Terminal dock: thin bottom strip with tabs; reads like a utility drawer, not a card.

Detailed interaction notes:

- Model picker: floating menu is anchored to the composer footer, around 340px wide, with a search input at the top, flat rows, provider/model icon, model name, effort label, and a right-aligned shortcut/check. The lower utility section has `Effort` as a nested row, a `Fast` switch row, and a footer-like edit/cycle control.
- New thread: the tab-strip `+` opens a tiny floating menu with two rows (`Chat`, `Browser`) and keyboard shortcuts aligned to the right. The menu is narrow, unadorned, and not a wizard.
- Settings: settings are full-window, left-nav plus one broad content column. Main settings are rows with label and help text on the left, controls on the right, and thin separators. Avoid cards inside settings except where selecting repeated items, such as the default model loadout.
- Default models: top loadout uses compact selectable cards, then provider columns use reorderable rows with subtle borders and drag handles. The visual system is still mostly white space and separators.
- Settings dialogs: Conductor uses either centered compact modals (`Add MCP server`) or a right-side sheet (`Add environment variable`), both with a dimmed/blurry page behind them and a sticky action footer.
- Repository settings: repository rows expand inline in the settings nav with two child items, `Git` and `Scripts`. The content pane remains sparse: repo Git has a simple default-branch row; repo Scripts uses Personal/Shared tabs, one Add button, a small status line, and no card stack.
- Terminal: captured layout confirms a thin terminal tab strip (`Run`, terminal tabs, `+`) inside the right utility panel. The exact add-tab popup still needs a fresh local capture.

Capture gap:

- Fresh local screenshot of the terminal add-tab popup is still needed. The latest successful settings pass did not revisit terminal controls.
