import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('recovered tool errors are muted while expanded errors retain their status', async ({ page }) => {
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Recovered errors');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.getByRole('navigation', { name: 'Project tracks', exact: true })
    .getByRole('button', { name: 'New track', exact: true }).click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await composer.fill('Demonstrate a recovered tool error');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  const turn = page.locator('.workspace-turn').filter({ hasText: 'The fix is complete.' });
  const summary = turn.locator('.workspace-work > summary');
  const recovered = summary.locator('.tool-recovered');
  await expect(recovered).toHaveText('1 recovered tool error');
  await expect(summary.locator('.tool-error')).toHaveCount(0);
  expect(await recovered.evaluate(el => getComputedStyle(el).color))
    .toBe(await summary.evaluate(el => getComputedStyle(el).color));
  await summary.click();
  const failed = turn.locator('.workspace-tool').filter({ has: page.locator('.tool-error') });
  await expect(failed.locator('.tool-error')).toHaveText('error');
  expect(await failed.locator('.tool-error').evaluate(el => getComputedStyle(el).color))
    .not.toBe(await recovered.evaluate(el => getComputedStyle(el).color));
  await failed.locator('summary').click();
  await expect(failed).toContainText('1 test failed');
});
