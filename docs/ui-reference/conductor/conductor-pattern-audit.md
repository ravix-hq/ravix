# RAV-46 — Conductor pattern audit

> Historical notes from the 2026-10-03 capture session; checklist items describe that session, not current implementation status. See [the capture index](README.md) for every image and known capture limitations.

Reference: `conductor-ui-reference.md`; all 11 JPEGs in `conductor-tour/`, captured 2026-10-03. Reviewed against Ravix's current templates and CSS, including concurrent uncommitted UI work. No product files changed.

## Evidence and limits

All captures are 1400 × 878 pixels. Dimensions below are approximate **image-space measurements**, not verified native points or CSS pixels. Use the proposed CSS values as visual starting points at a 1400px browser viewport; validate in the rendered app. Font family, exact colors, hover behavior, and responsive behavior cannot be established from these JPEGs.

| Capture | Actual visible state |
| --- | --- |
| `01-current-workstation.jpg` | Active chat, All files, expanded terminal beneath the right panel |
| `02-command-palette.jpg` | Open command palette with recent workspaces and actions |
| `03-create-entry.jpg` | Chat remains visible; **no create flow captured** |
| `04-search-section.jpg` | Chat remains visible; **no Search page captured** |
| `05-routines-section.jpg` | Chat remains visible; **no Routines page captured** |
| `06-home-section.jpg` | Home, filters, workspace rows grouped by recency |
| `07-settings.jpg` | Home remains visible; **no Settings captured** |
| `08-right-changes.jpg` | All files selected, completed conversation, collapsed dock |
| `09-right-checks.jpg` | Changes selected, empty state |
| `10-right-review.jpg` | Checks selected, sparse PR title/description; no populated review |
| `11-terminal-panel.jpg` | Same Checks state, dock remains collapsed |

These are visual preferences for Ravix's existing pre-PMF desktop UI, not performance or architecture recommendations. No production scale claim is made or new backend machinery proposed. Conductor “workspace” maps most closely to a Ravix **track**; keep Ravix's distinct workspace/project/track ownership and navigation semantics.

## Region checklist

### Rail → `workspace_live.html.heex`, `.yard`, `.yard-nav`, `.workspace-track`

- [ ] Make Create the same quiet, full-width row treatment as Home/Search/Routines. The screenshot reserves the dark create action for the Home header.
- [ ] Use one icon/text grid: ~14px icon, 8–10px gap, text beginning ~32px from window edge; nested Ravix tracks retain their necessary indent.
- [ ] Keep rows 32–36px tall, section labels 11–12px and sentence case, with ~16–20px separation between groups. Selected rows use a pale gray fill and ~5px radius, without a border or shadow.
- [ ] Keep age/status trailing and stable; truncate titles before crowding status. Footer is a ~38px strip with a top hairline and small utility controls.
- [ ] Target ~240px initial rail width (capture: 237px); retain resize and collapse. Current CSS defaults to 272px with a 240px minimum. Existing 32px row token already matches.

### Home / workspace list → `workspace_live.html.heex` `#home`, `.home-recent`, `.recent-row`

- [ ] Center a ~760px content column within the area remaining after the rail. Capture bounds are approximately x=434–1196, with a compact title/action row at y=50 and filters at y=95.
- [ ] Use flat table-like rows: status/identity, flexible title, optional existing metadata, owner, age. Capture rows are ~36–38px; nearby rows have no divider or card border.
- [ ] Align header, search/filter controls and rows to the same column. Keep one dark primary action at the top right; light row highlight indicates the current/hovered item, though the screenshot alone cannot distinguish which.
- [ ] Preserve repository context on Ravix rows. Current `.recent-main` has two lines: move metadata into a desktop column only where it remains readable, with stacking at narrow widths.
- [ ] Recency headings and ~28–32px group gaps are a useful optional presentation step. Do not add diff-count fetches or new filter behavior solely to reproduce the screenshot.

### Chat transcript → `track_live.html.heex`, `.transcript-scroll`, `.workspace-turn`

- [ ] Use the full flexible center pane with ~26px transcript side insets; capture center is ~775px wide. Current 40px inset can be reduced. Retain readable prose limits at wider sizes.
- [ ] Assistant output sits directly on the canvas. Short user prompts fit their content and align right; longer prompts can occupy most of the column with a very light warm fill, small radius, and no pronounced border.
- [ ] Keep tool activity as compact disclosure rows with subdued icon, action label and single-line code preview. Existing expanded errors, approvals and actionable states must remain visible.
- [ ] Use ~13–14px body text, ~21–22px line height; 11–12px metadata; 16–24px paragraph/entry separation and ~32–40px between completed turns. Give sparse threads whitespace instead of stretching messages.
- [ ] Keep elapsed time, timestamp and copy/menu actions together under the completed response. Capture `08` is the clearest completed-turn reference.

### Composer → `.workspace-composer`, `.composer-box`, `.workspace-actions`

- [ ] Anchor outside transcript scrolling, ~15px from center-pane sides and viewport bottom. In `08`: x≈252–997, y≈723–863, a ~745 × 140px box.
- [ ] Use ~12–14px radius, one faint border, near-white fill and no visibly elevated shadow. Current radius 14px matches; remove/reduce `.composer-box`'s raised shadow for this surface only.
- [ ] Target ~140px total empty height on a tall desktop viewport, with ~16px input padding and a ~32px footer. Current textarea minimum is 68px; increase available writing space without fixing the whole box height. Retain content growth and short-viewport behavior.
- [ ] Place model/reasoning text at lower left, attachment and send/stop at lower right, shortcut hint inside the upper-right input area. Keep all controls small and stable when send becomes stop.
- [ ] Preserve Ravix's Ask/Comment, queued prompts, attachments, connection and permission states; do not hide functional controls to achieve an empty-box screenshot match.

### Model picker → `model_menu.ex`, `runtime_picker.ex`, `.model-trigger`, `.model-menu`

- [ ] Copy the observed **closed trigger**: compact sans-serif model name, muted reasoning label, small chevron, transparent resting background, no pill border.
- [ ] Use the verified open-picker capture at `conductor-corrected-details/02-conductor-model-menu.jpg`: ~340px floating menu anchored above the composer footer, search row, flat 32px-ish model rows, provider icon, model name, effort label, right-aligned shortcut/check.
- [ ] Include the lower utility rows from the capture: `Effort` nested row, `Fast` switch row, and compact edit/cycle-effort footer. Keep Ravix's connected-runtime/provider constraints intact.
- [ ] Keep menu positioned above the composer and usable with keyboard/focus return. Do not infer model availability, pricing or backend semantics from Conductor's labels.

### Command palette → `workspace_live.html.heex` `#search-dialog`, `QuickJump` hook, search-result components

- [ ] Restyle the existing jump/search dialog as a ~620px floating sheet. `02` bounds: x≈390–1011, y≈209–670; use responsive width `min(620px, calc(100vw - 32px))`.
- [ ] Put the search field in a ~44px top row, separated by a hairline; avoid an additional large visible title above it. Keep an accessible dialog name and input label.
- [ ] Use small flat filter tabs, muted group labels, ~40px results, 8px row padding and trailing shortcuts/age. Selected result is a full pale-gray row with a small radius.
- [ ] Give the sheet a soft diffuse shadow and ~8px radius. The background remains clearly visible in `02`; reduce the dialog-specific scrim rather than changing every modal.
- [ ] Map existing projects/tracks/plans into the grouping. Conductor's Actions/Settings categories require separate product decisions; visual parity does not require new command infrastructure.

### Right panel → `track_live.html.heex` `#inspector`, `.workspace-tabs`, `.workspace-panel`

- [ ] Target ~380–400px initial width at 1400px (capture: 388px), preserving resizing and narrow-screen switching. Current `max(380px, 30vw)` produces 420px at 1400px.
- [ ] Keep panel flat, separated by one vertical hairline. Tabs are ~11–12px text with understated selected fill; counts are inline, not prominent badges. **The thin warm underline belongs to thread/dock tabs in these captures; inspector selection is different.**
- [ ] File rows are ~26px tall with ~14px icons and small monospace names; folders are neutral outlines, some file types use restrained color. Start with existing Ravix icons, without creating a new icon system.
- [ ] Empty Changes uses one unboxed outline icon, one short title and one faint helper line centered in remaining space. Scope any removal of `.empty .mark`'s border to inspector empty states.
- [ ] Keep populated diff/review/check styles provisional: `09` is empty Changes, and `10` contains no actual check results or discussion threads.

### Terminal dock → `machine_dock.ex`, `.dock-tabs`, terminal/Shell hooks

- [ ] Keep the drawer **under the right panel**, sharing its width. It does not span under the transcript in these captures.
- [ ] Reduce desktop tab strip from current 40px toward ~30–32px. Use thin top divider, flat 11–12px labels, small icons and a 1–2px active underline.
- [ ] Expanded `01` starts around y=440, roughly half the viewport; collapsed `08–11` leaves only the strip at y≈847. Preserve user resize/collapse state rather than fixing the height to that example.
- [ ] Output fills the drawer with ~8px padding, 11–12px monospace and no rounded inner card. Preserve Ravix's existing Commands, terminal sessions and machine stats semantics.

### Settings / create → `settings.ex`, `personal_settings.ex`, `project_settings.ex`, `workspace_settings.ex`, `new_project.ex`, new-track dialog

- [ ] Use verified settings captures: `conductor-settings-applescript/03-general.jpg`, `04-account.jpg`, `05-appearance.jpg`, `06-default-models.jpg`, `07-git.jpg`, `11-agents.jpg`, `12-prompts.jpg`, `13-environment.jpg`, `14-mcp.jpg`, plus `conductor-settings-submenus/01-ports.jpg` and `22-cloud-history-expanded.jpg`.
- [ ] Settings pattern: full-window left nav plus broad content column, search field in nav, rows with label/help text left, right-aligned controls, thin separators, almost no card chrome. Default models is the exception: compact selectable loadout cards plus provider columns of reorderable rows.
- [ ] Repository settings pattern: repo rows expand inline in the settings nav, then expose `Git` and `Scripts` child rows. Content stays sparse: repo Git is a default-branch setting; repo Scripts has Personal/Shared tabs, one Add button and a status/error line. See `conductor-settings-applescript/17-repo-detail-1.jpg` and `18-repo-detail-2.jpg`.
- [ ] Modal/sheet pattern: Environment's add-variable flow opens a right-side sheet with a sticky action footer; MCP's add-server flow opens a centered compact modal. Both dim and blur the underlying settings page. See `conductor-settings-submenus/17-environment-add-dialog.jpg` and `20-mcp-add-server-dialog.jpg`.
- [ ] Use the new-thread capture at `conductor-corrected-details/04-new-thread-opened.jpg`: a tab-strip `+` opens a tiny two-row floating menu (`Chat`, `Browser`) with right-aligned shortcuts. For Ravix, map this to project-row "open draft track" rather than reintroducing a global create flow.
- [ ] Preserve validation, unsaved-change handling, connected-agent status and destructive-action confirmation. Do not copy Conductor's workspace product model where Ravix intentionally differs.

## CSS starting values

Use existing tokens/selectors; adjust their owning declarations rather than appending another override layer.

| Rule | Suggested desktop target |
| --- | --- |
| Shell geometry | Rail 240px; inspector 388px; center flexible with `min-width: 0`; retain current mobile modes |
| Header rhythm | Capture top header ~36px plus thread strip ~38px; trial 36–40px where controls fit, versus current `--pane-head: 48px` |
| Row heights | Rail 32–36px; home 36–40px; file tree 26px; palette 40px |
| Borders | 1px neutral hairlines; no doubled adjacent borders |
| Radius | Flat panes 0; selected rows 4–6px; floating palette 8px; composer 12–14px |
| Elevation | None on panes/rows; near-zero on composer; soft shadow only on floating menus/dialogs |
| Type | UI 12–13px; prose 13–14px / 1.55–1.65; metadata 11–12px; section titles 16–18px; mostly weight 400, selective 500 |
| Icons | 14–16px neutral strokes, 8px text gap; retain accessible hit areas independent of glyph size |
| Color | White main canvas, near-white rail, pale neutral selection; reuse theme tokens. Exact JPEG color/contrast is not a target |

## Next changes, in order

1. **P0 — Shell proportions and rail hierarchy.** Trial 240/388px columns, quiet Create row, smaller header/dock strips. Existing rail height and theme work should be retained where already matching. Validate at 1400×878 first.
2. **P0 — Composer and transcript.** Reduce side insets and composer elevation; increase empty writing area; keep tool rows compact and completed turns separated. Check long text, streaming, queued and Comment states.
3. **P1 — Home density.** Center the list, align columns, remove repeated row/card chrome. Preserve first-visit quick start and repository context; grouping is optional.
4. **P1 — Search sheet and inspector finish.** Apply measured palette width/row rhythm; make inspector tabs/counts quiet and empty-state icon unboxed. Keep keyboard navigation, focus visibility and readable contrast.
5. **P2 — Model menu, settings/create and populated review polish.** Gather the missing states first; then make small local presentation changes.

These priorities are visual judgments, not measured user-impact rankings. Acceptance is manual visual comparison plus existing applicable checks; do not add tests for exact copy, markup, CSS classes or appearance. Verify desktop/narrow viewports, long names, resize/overflow, dark theme, and keyboard focus. Native preview/Mac runner and shared-browser scope remain deferred per ADR 0002.

## Additional captures needed from the local app

Use the same window size; wait until the intended state visibly appears before capture. Existing `01` already supplies an expanded terminal reference.

1. **Terminal add-tab menu:** the corrected pass still captured only the dock layout, not the popup.
2. **Populated Changes/Checks/Review:** file list, open diff, line discussion, successful/failed/pending checks, review controls.
3. **Search and Routines pages:** results/filter state, routine list and edit/create form; current named captures show neither.
4. **Optional:** model effort submenu, model/menu keyboard focus, composer attachments/slash suggestions, dark theme, narrow window and resized panes; Run output if dock controls are being redesigned.

Local Mac execution was re-enabled later on 2026-10-03, and the deeper settings captures now live in `conductor-settings-applescript/` and `conductor-settings-submenus/`.
