import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-89: the inspector's Files and Changes tabs, in a real browser. What the
// LiveView tests cannot show is layout (a long diff line wrapping inside a
// pane that widened for it) and time (a tab switch that does not wait on the
// machine), so this is where both are asserted.

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

// Slow every mock sandbox's directory and diff reads. The track's shared
// machine is the project's, and the suite runs one test at a time.
async function slowReads(request, ms) {
  const boxes = (await (await request.get(`${mock}/api/sandboxes`)).json()).data;
  for (const box of boxes) {
    expect((await request.post(`${mock}/__browser/read-delay`, { data: { id: box.id, ms } })).ok()).toBe(true);
  }
}

// A track on the mock's repository whose opening turn has made the worktree,
// so Files lists a checkout and Changes has a diff.
async function openTrack(page, login, name) {
  await signIn(page, login);
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'New project', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill(name);
  await expect(page.locator('#project-repositories option')).not.toHaveCount(0);
  await dialog.getByLabel('Repository', { exact: true }).fill('mockuser/atlas-api');
  await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#transcript-status')).toHaveText('Agent replied', { timeout: 30_000 });
  // The opening turn made the worktree after Files first read the directory.
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await expect(page.locator('.file-explorer').getByRole('button', { name: 'src', exact: true })).toBeVisible();
}

// Click an inspector tab and time, inside the page, until `selector` is in
// the document. Timed in the page so Playwright's own polling is not counted.
async function switchTab(page, tab, selector) {
  return page.evaluate(({ tab, selector }) => {
    const button = [...document.querySelectorAll('nav[aria-label="Inspector panels"] button')]
      .find(b => b.textContent.trim().startsWith(tab));
    return new Promise((resolve, reject) => {
      const start = performance.now();
      const observer = new MutationObserver(() => {
        if (document.querySelector(selector)) { observer.disconnect(); resolve(performance.now() - start); }
      });
      observer.observe(document.body, { childList: true, subtree: true });
      setTimeout(() => { observer.disconnect(); reject(new Error(`${tab} never showed ${selector}`)); }, 10_000);
      button.click();
    });
  }, { tab, selector });
}

test('Files hides .git, draws a kind per file, and keeps the ignored toggle in the toolbar', async ({ page }) => {
  test.setTimeout(120_000);
  await openTrack(page, 'inspectorfiles', 'Inspector files');
  const explorer = page.locator('.file-explorer');
  await expect(explorer.getByRole('button', { name: '.gitignore', exact: true })).toBeVisible();
  await expect(explorer.getByRole('button', { name: '.git', exact: true })).toHaveCount(0);
  for (const folder of ['public', 'scripts', 'src']) {
    const button = explorer.getByRole('button', { name: folder, exact: true });
    await button.click();
    await expect(button).toHaveAttribute('aria-expanded', 'true');
  }
  await expect(explorer.getByRole('button', { name: 'style.css', exact: true })).toBeVisible();
  await expect(explorer.getByRole('button', { name: 'index.ts', exact: true })).toBeVisible();

  // At least ten kinds, each its own glyph-and-colour pair.
  const kinds = await explorer.locator('.file-kind').evaluateAll(icons => icons.map(icon => [
    icon.dataset.kind, icon.innerHTML, getComputedStyle(icon).color,
  ]));
  const byKind = new Map(kinds.map(([kind, glyph, colour]) => [kind, `${glyph}|${colour}`]));
  expect(byKind.size).toBeGreaterThanOrEqual(10);
  expect(new Set(byKind.values()).size).toBe(byKind.size);

  // The toggle is an icon beside Refresh, named and pressed, not a pill in the tree.
  const toolbar = page.getByRole('navigation', { name: 'Inspector panels' });
  const toggle = toolbar.getByRole('button', { name: 'Show ignored files', exact: true });
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await expect(explorer.getByRole('button', { name: 'Show ignored files' })).toHaveCount(0);
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  await toggle.press('Space');
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  // It belongs to Files, and goes with it.
  await page.getByRole('button', { name: /^Changes/ }).click();
  await expect(page.locator('.change-file').first()).toBeVisible();
  await expect(toggle).toHaveCount(0);
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});

test('Files and Changes switch from what was loaded while a slow machine refreshes them', async ({ page, request }) => {
  test.setTimeout(120_000);
  await openTrack(page, 'inspectorswitch', 'Inspector switch');
  // Changes' first visit reads the diff; after that, both tabs are loaded.
  await page.getByRole('button', { name: /^Changes/ }).click();
  await expect(page.locator('.change-file')).toHaveCount(2);

  // Every read now takes a second and a half. A switch that waited on one
  // could not come in under 100 ms.
  await slowReads(request, 1500);
  try {
    for (const [tab, selector] of [['Files', '.file-explorer'], ['Changes', '.changes-panel'], ['Files', '.file-explorer'], ['Changes', '.changes-panel']]) {
      const ms = await switchTab(page, tab, selector);
      expect(ms, `${tab} took ${ms.toFixed(0)} ms`).toBeLessThan(100);
    }
    // The refresh is out, and says so on the button rather than blanking the list.
    await expect(page.locator('.panel-refresh.busy')).toBeVisible();
    await expect(page.locator('.change-file')).toHaveCount(2);
    await expect(page.locator('.panel-refresh.busy')).toHaveCount(0, { timeout: 10_000 });
    await expect(page.locator('.change-file')).toHaveCount(2);
  } finally {
    await slowReads(request, 0);
  }
});

test('a diff opens wide and wraps a line longer than the pane', async ({ page }) => {
  test.setTimeout(120_000);
  await openTrack(page, 'inspectordiff', 'Inspector diff');
  await page.getByRole('button', { name: /^Changes/ }).click();
  const inspector = page.locator('#inspector');
  const narrow = (await inspector.boundingBox()).width;
  await page.locator('.change-file', { hasText: 'window.ts' }).click();
  const diff = page.getByRole('region', { name: 'Diff for src/lib/window.ts' });
  await expect(diff).toBeVisible();

  // About half the stage while a diff is open, and back when it closes.
  const stage = await page.locator('.stage').boundingBox();
  await expect.poll(async () => (await inspector.boundingBox()).width).toBeGreaterThanOrEqual(stage.width * 0.49);
  expect((await inspector.boundingBox()).width).toBeGreaterThan(narrow);

  // Nothing scrolls sideways, and the long line's last words are inside the pane.
  const long = diff.locator('.diff-line code', { hasText: 'A line longer than any inspector' });
  await expect(long).toBeVisible();
  const box = await diff.boundingBox();
  const words = await long.evaluate(code => {
    const range = document.createRange();
    range.selectNodeContents(code);
    const rects = [...range.getClientRects()];
    return { right: Math.max(...rects.map(r => r.right)), lines: rects.length };
  });
  expect(words.lines).toBeGreaterThan(1);
  expect(words.right).toBeLessThanOrEqual(box.x + box.width + 1);
  expect(await diff.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

  await page.getByRole('button', { name: '← All changed files' }).click();
  await expect.poll(async () => (await inspector.boundingBox()).width).toBeLessThan(stage.width * 0.45);
});

// Opt-in: the PR's before/after pictures. `RAV89_SHOTS=<dir> RAV89_PHASE=before|after`.
test('inspector evidence', async ({ page }) => {
  test.skip(!process.env.RAV89_PHASE, 'Opt-in screenshot capture');
  test.setTimeout(120_000);
  const shot = name => `${process.env.RAV89_SHOTS || test.info().outputPath()}/${process.env.RAV89_PHASE}-${name}.png`;
  await openTrack(page, 'inspectorevidence', 'Inspector evidence');
  const explorer = page.locator('.file-explorer');
  for (const folder of ['public', 'src']) await explorer.getByRole('button', { name: folder, exact: true }).click();
  await expect(explorer.getByRole('button', { name: 'style.css', exact: true })).toBeVisible();
  await expect(explorer.getByRole('button', { name: 'index.ts', exact: true })).toBeVisible();
  await page.mouse.move(0, 0);
  await page.screenshot({ path: shot('files') });

  await page.locator('button[phx-click="toggle-ignored"]').click();
  await expect(page.locator('button[phx-click="toggle-ignored"]')).toHaveAttribute('aria-pressed', 'true');
  await page.mouse.move(0, 0);
  await page.locator('#inspector').screenshot({ path: shot('ignored-toggle') });

  await page.getByRole('button', { name: /^Changes/ }).click();
  await page.locator('.change-file', { hasText: 'window.ts' }).click();
  await expect(page.getByRole('region', { name: 'Diff for src/lib/window.ts' })).toBeVisible();
  await page.waitForTimeout(300); // the width settles; a picture, not an assertion
  await page.mouse.move(0, 0);
  await page.screenshot({ path: shot('changes-diff') });
});
