import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('layout evidence', async ({ page }, testInfo) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Ravix layout');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).not.toBeVisible();
  await page.locator('#yard .workspace-project.current .project-add').click();
  const track = page.getByRole('dialog', { name: 'New track', exact: true });
  await track.getByRole('button', { name: 'Advanced', exact: true }).click();
  await track.getByLabel('Branch name').fill('layout-example');
  await track.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  for (const width of [1280, 500]) {
    await page.setViewportSize({ width, height: 900 });
    if (width === 1280) await page.locator(".workspace-project.current .workspace-project-row").hover();
    const path = name => process.env.LAYOUT_PHASE
      ? `docs/screenshots/rav-9/${process.env.LAYOUT_PHASE}-${name}.png`
      : testInfo.outputPath(`${name}.png`);
    await page.screenshot({ path: path(width) });
    if (width === 500) {
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
      await page.locator('.workspace-project.current .workspace-project-row').hover();
      await page.screenshot({ path: path('500-sidebar') });
    }
  }
});
