import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openProjectSettings, saveMachine } from './settings.js';

test('project run script is inherited: run, ready, restart, stop and plain override', async ({ page }) => {
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('Run script browser');
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();

  const trackUrl = page.url();
  const settings = await openProjectSettings(page, 'machine');
  await settings.locator('#default-directory').fill('.');
  await settings.locator('#default-command').fill('npm run dev -- --port "$PORT" --strictPort');
  await settings.locator('#default-readiness').fill('/');
  // The run script alone needs no new machine: the open track stays.
  const question = await saveMachine(page, ['run script edited']);
  expect(question).toContain('Save these changes?');
  expect(question).toContain('The machine is not rebuilt.');
  await expect(page.getByText('Machine settings saved.', { exact: true })).toBeVisible();
  await page.goBack();
  await page.goBack();
  await expect(page).toHaveURL(trackUrl);

  await page.locator('button[phx-click="panel"][phx-value-name="preview"]').click();
  const status = page.locator('#run-status');
  // Stopped, the panel is its empty state and Run is that state's action.
  const empty = page.locator('#preview-empty');
  const run = empty.getByRole('button', { name: 'Run', exact: true });
  const restart = page.locator('button[phx-value-action="restart-run"]');
  const stop = page.locator('button[phx-value-action="stop"]');
  await expect(empty).toContainText('No preview running');
  await run.click();
  await expect(status).toHaveText('Status: ready');
  await expect(page.locator('button[phx-value-action="open"]')).toBeVisible();
  await restart.click();
  await expect(restart).toBeEnabled();
  await expect(status).toHaveText('Status: ready');
  // Logs are read once per click, and "ready" above can still be the run
  // before the restart: the new process may not have printed yet. Ask again
  // until its output arrives rather than reading one early snapshot.
  await expect(async () => {
    await page.locator('button[phx-value-action="logs"]').click();
    await expect(page.locator('#preview-logs pre')).toContainText('VITE', { timeout: 2_000 });
  }).toPass({ timeout: 20_000 });
  await stop.click();
  await expect(empty).toContainText('No preview running');

  await page.getByText('Run script override', { exact: true }).click();
  // Open by the reader and left open by every patch that follows: a status
  // refresh landing here used to collapse the section mid-edit.
  await expect(page.locator('#preview-path')).toBeVisible();
  await page.locator('#preview-path').fill('');
  await page.locator('#preview-config-form').getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.locator('#run-keeps-awake')).toHaveText("Keeps this track's machine awake while running");
  await run.click();
  await expect(status).toHaveText('Status: running');
  await expect(page.locator('button[phx-value-action="open"]')).toHaveCount(0);
  await expect(page.locator('iframe.workspace-preview')).toHaveCount(0);
  await stop.click();
  await expect(empty).toContainText('No preview running');
});
