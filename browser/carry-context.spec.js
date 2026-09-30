import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-50: a draft thread offers the track's other threads as chips; the
// picked ones travel with the first prompt and the sent message names them.
test('a new thread carries context from a sibling and shows where it came from', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Carried context');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'New track', exact: true })).toHaveCount(0);
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });

  const tabs = page.getByRole('navigation', { name: 'Threads', exact: true });
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  const send = page.getByRole('button', { name: 'Send', exact: true });
  const reply = 'There is one TODO worth doing here';

  // A sibling with a finished turn to carry.
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await tabs.getByRole('button', { name: 'Add thread', exact: true }).click();
  await composer.fill('Find the refund rounding bug');
  await send.click();
  await expect(page.locator('#thread-tab-draft')).toHaveCount(0);
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Find the refund rounding bug' })
    .locator('.agent-terminal-output > div > .md')).toContainText(reply, { timeout: 20_000 });

  // A new draft offers it, and the default thread, as toggles.
  await tabs.getByRole('button', { name: 'Add thread', exact: true }).click();
  const offer = page.getByRole('group', { name: 'Carry context from', exact: true });
  const sibling = offer.getByRole('button', { name: 'Find the refund rounding bug' });
  await expect(sibling).toHaveAttribute('aria-pressed', 'false');
  await sibling.click();
  await expect(sibling).toHaveAttribute('aria-pressed', 'true');
  const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);

  await composer.fill('Fix it and add a test');
  await send.click();
  await expect(page.locator('#thread-tab-draft')).toHaveCount(0);
  const turn = page.locator('.workspace-turn').filter({ hasText: 'Fix it and add a test' });
  await expect(turn.getByRole('group', { name: 'Imported context', exact: true }))
    .toContainText('Find the refund rounding bug', { timeout: 20_000 });
  // The person's words only; the digest is the agent's to read.
  await expect(turn.locator('.workspace-prompt')).toHaveText('Fix it and add a test');
  await expect(page.locator('#transcript-turns')).not.toContainText('imported thread context');
  await expect(page.locator('#draft-context')).toHaveCount(0);
});
