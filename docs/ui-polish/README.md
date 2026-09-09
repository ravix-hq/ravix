# PR #14 design in LiveView

Adapted [PR #14](https://github.com/ravix-hq/ravix/pull/14), commit
`794a172e5cf4e8aef304d6666ea010dcf791f1ef`, by Raunak Singwi, into the
Elixir rewrite in [PR #13](https://github.com/ravix-hq/ravix/pull/13).

The graphite/brass palette, IBM Plex typography, smaller radii, neutral primary
buttons, editorial landing page, sign-in card, stacked home actions, and quiet
workspace rows now render through Phoenix components and LiveView. Fonts are
bundled with their SIL license. Muted Ravix and Daylight text is adjusted for
contrast. The shared picker remains available before signing in.

The home actions reuse the existing project form: choose a GitHub repository or
name a scratch machine with no repository. Local projects remain disabled with
an explanation. Workspace forms, permissions, streaming, uploads, and previews
continue through the Elixir implementation.

## Review captures

These are the actual production build against local mock providers, captured
September 9, 2026. Desktop captures are 1280 pixels wide; mobile is 390 pixels.
They are review artifacts, not pixel-equality test baselines.

| Landing | Sign-in |
|---|---|
| ![Landing](landing.png) | ![Sign-in](login.png) |

| Home | Project |
|---|---|
| ![Home](home.png) | ![Project](project.png) |

| Inbox in Daylight | Track |
|---|---|
| ![Inbox](inbox-daylight.png) | ![Track](track.png) |

| Track in Daylight | Mobile track |
|---|---|
| ![Daylight](track-daylight.png) | ![Mobile](track-mobile.png) |

## Verification

Four Chromium flows cover public pages at 1280/820/390 pixels, sign-in at
1280/390, both palettes, local loading of all eight font faces, saved themes,
scratch projects and recent navigation, keyboard/dialog focus, streamed replies,
the actual image file chooser and submission, reconnect draft retention, and
session revocation. Axe reports no violations on the checked Ravix and Daylight
pages. Screenshots for the full matrix remain in the browser CI artifacts.

`mix precommit` passes 717 tests and four generated properties, with 92.16%
production coverage, plus 26 DOM/guard tests and the static/release gates.
