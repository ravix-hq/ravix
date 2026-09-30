import { expect } from '@playwright/test';

/**
 * No control in a track's header may sit over another, and a click on the
 * plan chip's centre must reach the chip. Playwright's own click only fails
 * on a cover after its timeout, and only where a spec happens to click; this
 * says which two overlap, at every width a spec measures (RAV-63).
 */
export async function expectHeaderUnobstructed(page) {
  const { overlaps, hit } = await page.locator('header.track-crumbs').evaluate(header => {
    const controls = [...header.querySelectorAll('a, button, .chip, [role=status], .track-private')]
      // A visually hidden element (the machine chip while Idle, RAV-82) covers nothing.
      .filter(el => !el.closest('.track-plan-popover, .sr-only') && el.getClientRects().length > 0);
    const name = el => el.getAttribute('aria-label') || el.textContent.trim().replace(/\s+/g, ' ').slice(0, 40);
    const overlaps = [];
    for (const [i, a] of controls.entries()) {
      for (const b of controls.slice(i + 1)) {
        if (a.contains(b) || b.contains(a)) continue;
        const r = a.getBoundingClientRect(), s = b.getBoundingClientRect();
        const w = Math.min(r.right, s.right) - Math.max(r.left, s.left);
        const h = Math.min(r.bottom, s.bottom) - Math.max(r.top, s.top);
        if (w > 0.5 && h > 0.5) overlaps.push(`${name(a)} × ${name(b)}`);
      }
    }
    const chip = header.querySelector('.track-plan-chip');
    let hit = null;
    if (chip) {
      const r = chip.getBoundingClientRect();
      const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      hit = !!at && chip.contains(at);
    }
    return { overlaps, hit };
  });
  expect(overlaps).toEqual([]);
  if (hit !== null) expect(hit).toBe(true);
}
