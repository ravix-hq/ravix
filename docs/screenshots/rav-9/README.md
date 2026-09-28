RAV-9 layout comparison

The before images show main at 7b68408 (including #302); after images show this
layout change. Both use the default Ravix theme, a mock account, and a new track,
at 1280×900 and 500×900. Capture with `LAYOUT_PHASE=after bun run test:browser
browser/layout-evidence.spec.js` after deploying production assets.

Inspector audit: #286 already supplies a full-height right panel, resize handle,
persisted collapse control, and independent scrolling. Keep those behaviors.
The main panel order is Files / Changes / Checks / Preview; Preview retains
#300's run controls, logs, and script overrides. The existing Commands and
Machine stats dock remains below it. Its empty-state shortcut now says Open
Preview to match its destination. Narrow screens retain Conversation / Files /
Commands navigation. No provider, terminal, or run lifecycle was rebuilt.

The comparison follows the RAV-9 owner decisions supplied with the track. A
live Conductor documentation lookup was unavailable in this environment.
