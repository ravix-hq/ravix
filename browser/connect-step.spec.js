import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-133/134/135: the agent-connection step inside Add a repository is a
// card of its own, refuses an empty paste in words rather than with the
// browser's bubble, and shows its progress in the button it was pressed on,
// with nothing moving under the pointer and the paste kept in the field.
const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

async function accessible(page) {
  await page.evaluate(() => Promise.all(document.getAnimations()
    .filter(a => a.effect?.getTiming?.().iterations !== Infinity)
    .map(a => a.finished.catch(() => {}))));
  const result = await new AxeBuilder({ page }).include('#new-project-dialog-dialog')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(result.violations.map(v => `${v.id}: ${v.nodes.map(n => n.target.join(' ')).join(', ')}`)).toEqual([]);
}

test('the connect step is a card whose button holds still while the token is checked', async ({ page, request }) => {
  await signIn(page, 'connectstep', '/home');
  await openAddRepository(page);
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.locator('#project-agent-claude').click();
  await expect(dialog.locator('#project-agent-claude')).toContainText('Not connected');

  // One card, headed for its agent; its button is plain and the dialog's
  // submit is the only primary one.
  const card = dialog.getByRole('group', { name: 'Connect Claude Code', exact: true });
  await expect(card).toBeVisible();
  await expect(card.getByText('claude setup-token')).toBeVisible();
  const field = card.getByLabel('Subscription token', { exact: true });
  // Found by id: while Fountain is asked, the button reads "Connecting…".
  const connect = card.locator('#credential-submit');
  await expect(connect).toHaveAccessibleName('Connect Claude Code');
  await expect(connect).not.toHaveClass(/primary/);
  // (The Subscription/API key tabs are pressed toggles drawn in the accent;
  // among the dialog's actions, only its own submit is primary.)
  await expect(dialog.locator('button.primary:not([aria-pressed])')).toHaveCount(1);
  await expect(dialog.getByRole('button', { name: 'Create scratch project', exact: true })).toHaveClass(/primary/);
  const cardBox = await card.boundingBox();
  const connectBox = await connect.boundingBox();
  const dialogBox = await dialog.boundingBox();
  expect(connectBox.width).toBeLessThan(cardBox.width / 2);
  expect(connectBox.x + connectBox.width).toBeLessThanOrEqual(cardBox.x + cardBox.width);
  expect(cardBox.x).toBeGreaterThan(dialogBox.x);
  await accessible(page);

  // An empty submit: the page's own sentence beside the field, nothing native.
  await expect(field).not.toHaveAttribute('required');
  await connect.click();
  const error = card.locator('#credential-value-error');
  await expect(error).toContainText('Paste the token from claude setup-token first.');
  await expect(field).toHaveAttribute('aria-invalid', 'true');
  await expect(field).toHaveAttribute('aria-describedby', /credential-value-error/);
  expect(await field.evaluate(el => el.validity.valid)).toBe(true);
  await expect(dialog.locator('.loading-status')).toHaveCount(0);
  await accessible(page);

  // A refused token stays in the field, so it is not pasted again.
  await field.fill('sk-ant-oat01-invalid');
  await connect.click();
  await expect(error).toContainText('Anthropic did not accept that');
  await expect(field).toHaveValue('sk-ant-oat01-invalid');
  expect(await page.content()).not.toContain('sk-ant-oat01-invalid');

  // While Fountain is asked: the button says so in the box it already had,
  // the field keeps the paste, and nothing is inserted above the form.
  expect((await request.post(`${mock}/__browser/credential-delay`, { data: { ms: 2500 } })).ok()).toBe(true);
  await field.fill('sk-ant-oat01-browser-fixture');
  const before = await connect.boundingBox();
  await connect.click();
  await expect(connect).toHaveAttribute('aria-busy', 'true');
  await expect(connect).toBeDisabled();
  await expect(connect).toHaveAccessibleName('Connecting…');
  const during = await connect.boundingBox();
  expect(during).toEqual(before);
  await expect(field).toHaveValue('sk-ant-oat01-browser-fixture');
  // The last refusal stays until the new answer replaces it, so nothing
  // above the button changes height either.
  await expect(error).toContainText('Anthropic did not accept that');
  await expect(dialog.locator('.loading-status')).toHaveCount(0);
  await expect(dialog.getByText('Updating agent connection')).toHaveCount(0);
  await expect(dialog.locator('#credential-status')).toHaveText('Connecting Claude Code…');
  const anchor = await dialog.locator('#project-agent-label').boundingBox();
  await accessible(page);

  // Then the step folds up and the fields under it move, the dialog's top
  // and the agent cards stay where they were, and the paste is gone with it.
  await expect(dialog.locator('#project-agent-claude')).toContainText('Connected', { timeout: 15_000 });
  await expect(card).toHaveCount(0);
  await expect(dialog.locator('#credential-value-error')).toHaveCount(0);
  expect(await dialog.locator('#project-agent-label').boundingBox()).toEqual(anchor);
  await expect(dialog.getByRole('button', { name: 'Create scratch project', exact: true })).toBeEnabled();
  expect(await page.content()).not.toContain('sk-ant-oat01-browser-fixture');
  await accessible(page);
  expect((await request.post(`${mock}/__browser/credential-delay`, { data: { ms: 0 } })).ok()).toBe(true);
});
