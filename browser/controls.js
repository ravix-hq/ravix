import { expect } from '@playwright/test';

// RAV-59: a radio or checkbox keeps its intrinsic size beside its label, and
// the label's text stays on one line. The intrinsic size is measured from a
// sibling control with the author styles reverted, so it holds in any theme.
export async function expectInlineChoice(label) {
  const layout = await label.evaluate(node => {
    const control = node.querySelector('input[type=radio], input[type=checkbox]');
    const probe = document.createElement('input');
    probe.type = control.type;
    probe.style.all = 'revert';
    control.after(probe);
    const intrinsic = probe.getBoundingClientRect().width;
    probe.remove();
    const text = [...node.childNodes].find(child => child !== control && child.textContent.trim());
    const range = document.createRange();
    range.selectNodeContents(text);
    const lines = new Set([...range.getClientRects()].map(rect => Math.round(rect.top)));
    const box = control.getBoundingClientRect();
    return { width: box.width, intrinsic, lines: lines.size, textLeft: range.getBoundingClientRect().left, controlRight: box.right };
  });
  expect(layout.width).toBeCloseTo(layout.intrinsic, 0);
  expect(layout.lines).toBe(1);
  // The text starts right after the control, not across the dialog.
  expect(layout.textLeft - layout.controlRight).toBeLessThan(16);
}
