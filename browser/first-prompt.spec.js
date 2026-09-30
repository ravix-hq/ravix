import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-47: the New track dialog takes an optional first prompt. Enter creates
// the track, and the prompt waits in its queue until setup is ready.
test('a first prompt typed in the create dialog opens the track with it waiting for setup', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('First prompt');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();

  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  const prompt = dialog.getByLabel('What do you want to work on?', { exact: true });
  await expect(prompt).toBeVisible();
  await expect(dialog.getByRole('button', { name: 'Create track', exact: true })).toBeEnabled();
  await prompt.fill('Add a health check endpoint');
  // Shift+Enter is a new line, not a submit.
  await prompt.press('Shift+Enter');
  await prompt.pressSequentially('and document it');
  await expect(prompt).toHaveValue('Add a health check endpoint\nand document it');
  await expect(dialog).toBeVisible();
  const axe = await new AxeBuilder({ page }).include('#new-track-dialog')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);

  await prompt.press('Enter');
  await expect(dialog).toHaveCount(0);
  const queue = page.locator('.workspace-queue');
  await expect(queue).toContainText('Add a health check endpoint');
  await expect(queue.locator('.chip')).toHaveText('Waiting');
  await expect(page.locator('#track-setup-status')).toContainText('Prompts will wait until setup is ready.');

  // Once setup is ready the queue delivers it as the thread's first message.
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  await expect(queue).toHaveCount(0, { timeout: 30_000 });
  await expect(page.locator('#transcript-turns .workspace-prompt')
    .filter({ hasText: 'Add a health check endpoint' })).toHaveCount(1, { timeout: 20_000 });
});
