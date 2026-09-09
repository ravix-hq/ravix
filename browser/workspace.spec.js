import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

async function accessible(page) {
  const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(result.violations).toEqual([]);
}

async function signIn(page) {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in ↗' }).click();
  await page.getByRole('link', { name: 'Sign in as @mockuser', exact: true }).click();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
}

test('landing and sign-in are accessible', async ({ page }) => {
  await page.goto('/');
  await accessible(page);
  await signIn(page);
  await accessible(page);
});

test('keyboard users can resize panels and close dialogs with focus restored', async ({ page }) => {
  await signIn(page);
  const handle = page.getByRole('separator', { name: 'Sidebar width' });
  await handle.focus();
  await handle.press('Home');
  await expect(handle).toHaveAttribute('aria-valuenow', '220');
  await handle.press('ArrowRight');
  await expect(handle).toHaveAttribute('aria-valuenow', '230');
  const open = page.getByRole('complementary', { name: 'Projects and tracks' }).getByRole('button', { name: 'New project' });
  await open.focus();
  await open.press('Enter');
  const dialog = page.getByRole('dialog', { name: 'New project' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('button', { name: 'Close', exact: true })).toBeFocused();
  await accessible(page);
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();
  await expect(open).toBeFocused();
});

test('project, track, streaming, image upload, reconnect, and revocation', async ({ page, context }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await signIn(page);
  await page.getByRole('button', { name: 'New project', exact: true }).first().click();
  const projectDialog = page.getByRole('dialog', { name: 'New project' });
  await expect(projectDialog).toBeVisible();
  await page.getByLabel('Project name', { exact: true }).fill('Browser quality');
  await expect(page.getByLabel('Repository', { exact: true }).locator('option')).not.toHaveCount(1);
  await page.getByLabel('Repository', { exact: true }).selectOption('mockuser/atlas-api');
  await projectDialog.getByRole('button', { name: 'Create project' }).click();
  await expect(projectDialog).not.toBeVisible();
  await page.locator('.crumbs').getByRole('button', { name: 'New track', exact: true }).click();
  await page.getByLabel('Track title').fill('Browser smoke');
  await page.getByRole('button', { name: 'Open track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await accessible(page);
  await composer.fill('Explain this project for the browser smoke test');
  await composer.press('Enter');
  await expect(page.locator('#transcript-turns')).toContainText('Explain this project for the browser smoke test');
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Explain this project for the browser smoke test' }).locator('.md')).toContainText('There is one TODO worth doing here');
  await expect(composer).toHaveValue('');
  // Interrupt the actual LiveSocket connection, preserving the browser's draft.
  await composer.fill('Draft survives reconnect');
  await page.evaluate(() => new Promise(resolve => window.liveSocket.disconnect(resolve)));
  await expect.poll(() => page.evaluate(() => window.liveSocket.getSocket().isConnected())).toBe(false);
  await page.evaluate(() => window.liveSocket.connect());
  await expect.poll(() => page.evaluate(() => window.liveSocket.getSocket().isConnected())).toBe(true);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(composer).toHaveValue('Draft survives reconnect');
  await page.getByLabel('Attach images').setInputFiles({
    name: 'pixel.png', mimeType: 'image/png',
    buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4WQAAAAASUVORK5CYII=', 'base64'),
  });
  await expect(page.locator('.workspace-upload')).toContainText('pixel.png');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.locator('.workspace-upload')).toHaveCount(0);
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Draft survives reconnect' }).locator('.md')).toContainText('There is one TODO worth doing here');
  // The same session is revoked from a second tab while the first remains connected.
  const trackURL = page.url();
  await composer.fill("This must never be sent");
  const other = await context.newPage();
  await other.goto('/home');
  await other.getByRole('link', { name: 'Sign out' }).click();
  await expect(other.getByRole('link', { name: 'Sign in ↗' })).toBeVisible();
  await page.evaluate(() => document.querySelector("#composer-form")?.requestSubmit());
  await expect(page.getByRole('link', { name: 'Sign in ↗' })).toBeVisible();
  await signIn(page);
  await page.goto(trackURL);
  await expect(page.locator("#transcript-turns")).toBeVisible();
  await expect(page.locator("#transcript-turns")).not.toContainText("This must never be sent");
  await page.screenshot({ path: test.info().outputPath("workspace.png"), fullPage: true });
  expect(errors).toEqual([]);
});
