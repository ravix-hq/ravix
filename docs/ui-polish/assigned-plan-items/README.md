# Assigned plan items

Four assigned items on one track, captured with the isolated Playwright app and provider mocks. The collapsed summary replaces four separate cards; the full list remains available without taking space from the conversation by default.

| Theme / viewport | Before | After, collapsed | Expanded list |
| --- | --- | --- | --- |
| Midnight, 1480 × 900 | [Before](assigned-before-midnight-1480.png) | [After](assigned-after-midnight-1480.png) | [List](assigned-list-midnight-1480.png) |
| Midnight, 500 × 900 | [Before](assigned-before-midnight-500.png) | [After](assigned-after-midnight-500.png) | [List](assigned-list-midnight-500.png) |
| Daylight, 1480 × 900 | [Before](assigned-before-daylight-1480.png) | [After](assigned-after-daylight-1480.png) | [List](assigned-list-daylight-1480.png) |
| Daylight, 500 × 900 | [Before](assigned-before-daylight-500.png) | [After](assigned-after-daylight-500.png) | [List](assigned-list-daylight-500.png) |

`browser/assigned-plan-items.spec.js` recreates the after screenshots and checks collapsed height, horizontal overflow, item disclosures, note submission, and axe WCAG 2 A/AA in both themes and widths. The baseline was captured before the implementation with the same four-item fixture; generated track names differ between runs.

Statuses retain Plans' existing semantics: items assigned to the same track share that track's PR evidence. These screenshots show four in-progress items. LiveView tests separately exercise mixed status ordering, PR links, done counts, and the all-done summary. Only merged PR evidence counts as done; closing an unmerged track or PR does not.
