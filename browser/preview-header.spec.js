import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-42: the header says whether the track has a preview and opens the
// Preview tab, on a desktop with the inspector shut and on a phone where
// the inspector is a view of its own. It never starts one itself.
test('RAV-42: the header Preview control opens the Preview tab at desktop and phone width', async ({ page }) => {
  test.setTimeout(180_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Preview header');
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });

  const control = page.locator('#track-header #track-preview');
  const tabs = page.locator('#inspector > .workspace-tabs');
  const empty = page.locator('#preview-empty');

  // Nothing has run: the header offers to start one, from the Files tab.
  await expect(control).toHaveText('Start preview');
  await expect(control).toHaveClass(/preview-stopped/);
  await expect(tabs.locator('button.selected')).toHaveText('Files');

  // With the inspector shut, the control opens it on the Preview tab.
  await page.locator('#inspector-toggle').click();
  await expect(page.locator('html')).toHaveAttribute('data-inspector', 'closed');
  await control.click();
  await expect(page.locator('html')).not.toHaveAttribute('data-inspector', 'closed');
  await expect(tabs.locator('button.selected')).toHaveText('Preview');
  await expect(empty.locator('h3')).toHaveText('No preview running');
  await expect(empty.getByRole('button', { name: 'Run', exact: true })).toBeEnabled();
  await expect(empty.locator('.empty-hint')).toHaveText('or ask the agent to start one');
  // Opening the tab started nothing.
  await expect(page.locator('#run-status')).toHaveCount(0);
  await expect(control).toHaveText('Start preview');
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

  // Run it, and the header follows without a click.
  await page.locator('#preview-run-script').click();
  await page.locator('#preview-directory').fill('.');
  await page.locator('#preview-command').fill('npm run dev -- --port "$PORT" --strictPort');
  await page.locator('#preview-path').fill('/');
  await page.locator('#preview-config-form').getByRole('button', { name: 'Save', exact: true }).click();
  await expect(empty.locator('h3')).toHaveText('No preview running');
  await empty.getByRole('button', { name: 'Run', exact: true }).click();
  await expect(page.locator('#run-status')).toHaveText('Status: ready', { timeout: 60_000 });
  await expect(control).toHaveClass(/preview-ready/);
  await expect(control).toHaveText('Preview');
  await expect(control.locator('.dot.ready')).toBeVisible();

  // A phone: the control is in the header on the conversation, and opens
  // the inspector as the page's own Files button does.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.reload();
  await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1);
  await page.getByRole('button', { name: 'Conversation', exact: true }).click();
  await expect(page.locator('.track-conversation')).toBeVisible();
  await expect(page.locator('#inspector')).toBeHidden();
  await expect(control).toBeVisible();
  await expect(control).toHaveClass(/preview-ready/);
  await control.click();
  await expect(page.locator('#inspector')).toBeVisible();
  await expect(page.locator('.track-conversation')).toBeHidden();
  await expect(tabs.locator('button.selected')).toHaveText('Preview');
  await expect(page.locator('#run-status')).toHaveText('Status: ready');

  // Stopped again, the phone's control offers to start one and opens the
  // empty state.
  await page.locator('button[phx-value-action="stop"]').click();
  await expect(empty.locator('h3')).toHaveText('No preview running', { timeout: 30_000 });
  await expect(control).toHaveClass(/preview-stopped/);
  await page.getByRole('button', { name: 'Conversation', exact: true }).click();
  await control.click();
  await expect(empty).toBeVisible();
  await expect(empty.locator('.empty-hint')).toHaveText('or ask the agent to start one');
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});
