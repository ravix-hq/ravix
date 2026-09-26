# Plan progress

Captured by `browser/plans.spec.js` from the real application with an isolated
browser-test database. The plan has three unstarted items, including one blocked
on its dependency. The list uses the same server-derived progress summary as the
plan detail and the track row (guests see only assigned-item counts).

- [Desktop, midnight](plan-progress-midnight-1480.png)
- [500 px, midnight](plan-progress-midnight-500.png)
- [Desktop, daylight](plan-progress-daylight-1480.png)
- [500 px, daylight](plan-progress-daylight-500.png)

The browser test checks both themes for overflow and axe WCAG 2 A/AA violations.
The LiveView regression covers mixed PR states: 25% complete, 1 WIP, and
1 unstarted (1 blocked), with a closed-without-merge item excluded from completion.
Percentages are whole numbers rounded down; an empty plan is 0% complete.
