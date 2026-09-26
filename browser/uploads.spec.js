import { test, expect } from '@playwright/test';
import { signIn } from './sign-in.js';

test('images upload before Send and remain visible in conversation history', async ({ page }) => {
  test.setTimeout(90_000);
  await signIn(page, 'eli');
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project' });
  await project.getByLabel('Project name', { exact: true }).fill('Image uploads');
  await project.getByRole('button', { name: 'Create project' }).click();
  await expect(project).not.toBeVisible();
  await page.getByRole('navigation', { name: 'Project tracks', exact: true })
    .getByRole('button', { name: 'New track', exact: true }).click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await composer.fill('Describe these images');

  const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4WQAAAAASUVORK5CYII=';
  const chooserOpened = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose images', exact: true }).click();
  await (await chooserOpened).setFiles({ name: 'picker.png', mimeType: 'image/png', buffer: Buffer.from(png, 'base64') });
  const uploads = page.locator('.workspace-upload');
  await expect(uploads).toContainText('picker.png (100%)');
  await uploads.getByRole('button', { name: 'Remove', exact: true }).click();
  await expect(uploads).toHaveCount(0);

  for (const gesture of ['paste', 'drop']) {
    await composer.evaluate((el, { gesture, png }) => {
      const transfer = new DataTransfer();
      transfer.items.add(new File([Uint8Array.from(atob(png), c => c.charCodeAt(0))], `${gesture}.png`, { type: 'image/png' }));
      const event = gesture === 'paste'
        ? new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer })
        : new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: transfer });
      el.dispatchEvent(event);
    }, { gesture, png });
    await expect(uploads.filter({ hasText: `${gesture}.png` })).toContainText('(100%)');
  }
  await expect(uploads).toHaveCount(2);
  await expect(composer).toHaveValue('Describe these images');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(uploads).toHaveCount(0);
  await expect(composer).toHaveValue('');

  const message = page.locator('.workspace-turn').filter({ hasText: 'Describe these images' });
  const images = message.locator('.said img');
  // Delivery may wait for the queue's 30-second idle sweep.
  await expect(images).toHaveCount(2, { timeout: 45_000 });
  for (const image of await images.all()) {
    await expect.poll(() => image.evaluate(el => el.complete && el.naturalWidth > 0)).toBe(true);
  }
  const imageUrl = await images.first().getAttribute('src');
  const response = await page.request.get(imageUrl, { headers: { Accept: 'image/png' } });
  expect(response.status()).toBe(200);
  expect(await response.body()).toEqual(Buffer.from(png, 'base64'));

  await page.reload();
  await expect(images).toHaveCount(2);
  for (const image of await images.all()) {
    await expect.poll(() => image.evaluate(el => el.complete && el.naturalWidth > 0)).toBe(true);
  }
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});
