import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// RAV-101: the inspector's Checks, Preview and toolbar, and the dock's
// Machine stats and "+". `SCREENSHOT_DIR` saves the review shots.
test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

const shoot = async (target, name) => {
  if (process.env.SCREENSHOT_DIR) await target.screenshot({ path: `${process.env.SCREENSHOT_DIR}/${name}.png` });
};

test('inspector and dock polish', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'inspectorpolish', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'Add a repository' });
  await dialog.getByLabel('Project name', { exact: true }).fill('Atlas API');
  await expect(dialog.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await dialog.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await dialog.getByRole('button', { name: 'Add repository' }).click();
  await expect(dialog).not.toBeVisible();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 45_000 });
  const tabs = page.getByRole('navigation', { name: 'Inspector panels' });
  const heights = locator => locator.evaluateAll(els => els.map(el => Math.round(el.getBoundingClientRect().height)));
  const top = async locator => Math.round((await locator.boundingBox()).y);

  // The toolbar's icon says what it refreshes.
  await expect(tabs.locator('.panel-refresh')).toHaveAttribute('title', 'Refresh files');

  // Checks: no green 0, even rows, and "no checks" right under them.
  await tabs.getByRole('button', { name: 'Checks', exact: true }).click();
  await expect(page.locator('#git-uncommitted')).toBeVisible({ timeout: 15_000 });
  await expect(page.locator('#checks-empty')).toBeVisible();
  expect(new Set(await heights(page.locator('#git-status .git-row'))).size).toBe(1);
  const rows = await page.locator('#git-status').boundingBox();
  // Its mark, not just its box, sits right under the rows.
  expect((await page.locator('#checks-empty .mark').boundingBox()).y - (rows.y + rows.height)).toBeLessThan(40);
  await expect(tabs.locator('.panel-refresh')).toHaveAttribute('title', 'Refresh checks');
  await shoot(page.locator('#inspector'), 'checks');

  // Preview, idle: one empty state, one primary action, a small link.
  await tabs.getByRole('button', { name: 'Preview', exact: true }).click();
  const empty = page.locator('#preview-empty');
  await expect(empty).toContainText('No preview running');
  await expect(page.locator('#inspector .workspace-panel button.primary:visible')).toHaveCount(1);
  await expect(page.locator('#inspector').getByRole('button', { name: 'Logs', exact: true })).toHaveCount(0);
  await expect(page.locator('#preview-logs')).toHaveCount(0);
  await expect(page.getByText('Run script override', { exact: true })).toBeHidden();
  await shoot(page.locator('#inspector'), 'preview');
  await empty.getByRole('button', { name: 'Run script…', exact: true }).click();
  await expect(page.locator('#preview-directory')).toBeFocused();
  await expect(page.locator('#preview-config summary .disclosure-chevron')).toBeVisible();
  await shoot(page.locator('#inspector'), 'preview-run-script');

  // Machine stats: 6px bars, even rows, when they were read.
  await page.getByRole('button', { name: 'Machine stats', exact: true }).click();
  await expect(page.locator('.machine-stats')).toBeVisible({ timeout: 15_000 });
  expect(new Set(await heights(page.locator('.machine-stats > div'))).size).toBe(1);
  for (const h of await heights(page.locator('.stat-bar'))) expect(h).toBe(6);
  await expect(page.locator('#machine-stats-updated')).toContainText(/Updated\s+(just now|\d+m ago)/);
  await shoot(page, 'machine-stats');
  await shoot(page.locator('#machine-dock-panel, .machine-dock-host').first(), 'machine-stats-dock');

  // The dock does not reflow as its tabs change, a terminal opens or closes.
  const dock = page.locator('.machine-dock-host');
  const at = await top(dock);
  const panelHeight = Math.round((await page.locator('#inspector > .workspace-panel, #inspector .workspace-panel').first().boundingBox()).height);
  await page.getByRole('button', { name: 'Commands', exact: true }).click();
  expect(await top(dock)).toBe(at);

  // "+" is a menu; nothing opens until an item is chosen.
  await page.locator('#dock-add-trigger').click();
  const menu = page.locator('#dock-add-menu');
  await expect(menu).toBeVisible();
  await expect(menu.getByRole('menuitem', { name: /New terminal/ })).toContainText('⌃`');
  await expect(menu.getByRole('menuitem', { name: 'Run script' })).toBeVisible();
  await expect(page.locator('[data-shell-tab]')).toHaveCount(0);
  await shoot(page.locator('#inspector'), 'dock-add-menu');
  await menu.getByRole('menuitem', { name: /New terminal/ }).click();
  const tab = page.locator('[data-shell-tab]');
  await expect(tab).toHaveCount(1);
  expect(await top(dock)).toBe(at);
  expect(Math.round((await page.locator('#inspector > .workspace-panel, #inspector .workspace-panel').first().boundingBox()).height)).toBe(panelHeight);
  const close = tab.locator('.dock-shell-close');
  await page.locator('#inspector > .workspace-panel, #inspector .workspace-panel').first().hover();
  await expect(close).toHaveCSS('opacity', '0');
  await tab.hover();
  await expect(close).toHaveCSS('opacity', '1');
  await expect(tab.locator('.dock-tab')).toHaveCSS('border-bottom-color', await page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()).then(hex => {
    const n = parseInt(hex.slice(1), 16);
    return `rgb(${n >> 16}, ${(n >> 8) & 255}, ${n & 255})`;
  }));
  await shoot(page.locator('#inspector'), 'dock-terminal-tab');
  await close.click();
  await expect(tab).toHaveCount(0);
  expect(await top(dock)).toBe(at);

  // The machine's state is the header's; no status line survives above the dock.
  await expect(page.locator('#inspector').getByText("This track's machine")).toHaveCount(0);
  await expect(page.locator('.dock-context')).toHaveCount(0);
});
