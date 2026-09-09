import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

async function accessible(page) {
  const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(result.violations).toEqual([]);
}

async function signIn(page) {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in', exact: true }).click();
  await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
  await page.getByRole('link', { name: 'Sign in as @mockuser', exact: true }).click();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
}

async function chooseTheme(page, name) {
  await page.locator('[data-theme-toggle]').click();
  await page.getByRole('menuitemradio', { name, exact: true }).click({ timeout: 15_000 });
  await expect(page.locator('html')).toHaveAttribute('data-theme', name.toLowerCase());
  // Measure the selected palette after its CSS transitions, not a mixed frame.
  await page.evaluate(async () => {
    await new Promise(requestAnimationFrame);
    await Promise.all(document.getAnimations().filter(animation => animation instanceof CSSTransition).map(animation => animation.finished.catch(() => {})));
  });
}

async function fitsViewport(page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
}

async function capture(page, name) {
  await fitsViewport(page);
  await page.screenshot({ path: test.info().outputPath(`${name}.png`), fullPage: true });
}

test('public design loads local Plex fonts and works in dark, light, and narrow layouts', async ({ page }) => {
  test.setTimeout(120_000);
  await page.goto('/');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const fonts = await page.evaluate(async () => {
    const faces = [...document.fonts];
    await Promise.all(faces.map(face => face.load()));
    return faces.map(face => ({ family: face.family, status: face.status }));
  });
  expect(fonts).toHaveLength(8);
  expect(fonts.every(font => font.status === 'loaded' && font.family.startsWith('IBM Plex'))).toBe(true);
  expect(await page.evaluate(() => performance.getEntriesByType('resource').filter(entry => entry.name.includes('.woff2')).every(entry => new URL(entry.name).origin === location.origin))).toBe(true);
  for (const theme of ['Ravix', 'Daylight']) {
    await chooseTheme(page, theme);
    for (const width of [1280, 820, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await accessible(page);
      await capture(page, `landing-${theme}-${width}`);
    }
  }
  await page.getByRole('link', { name: 'Sign in', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
  for (const theme of ['Daylight', 'Ravix']) {
    await chooseTheme(page, theme);
    for (const width of [390, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      await accessible(page);
      await capture(page, `login-${theme}-${width}`);
    }
  }
  await page.getByRole('link', { name: 'About Ravix' }).click();
  await expect(page.getByRole('heading', { name: 'One project. Many tracks.' })).toBeVisible();
});

test('home quick start creates a scratch project and recent navigation survives theme changes', async ({ page }) => {
  await signIn(page);
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  await expect(page.getByRole('button', { name: /Open a local project/ })).toBeDisabled();
  await accessible(page);
  await capture(page, 'home-empty');
  await page.getByRole('button', { name: /^Quick start/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Quick start quality');
  await expect(page.getByLabel('Repository', { exact: true })).toHaveValue('');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Quick start quality' })).toBeVisible();
  await capture(page, 'project-empty');
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  const recent = page.getByRole('region', { name: 'Recent projects' });
  await expect(recent).toContainText('Quick start quality');
  await expect(recent).toContainText('no repository');
  for (const theme of ['Ravix', 'Daylight']) {
    await chooseTheme(page, theme);
    await accessible(page);
    await capture(page, `home-${theme}`);
  }
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
  await recent.getByRole('link', { name: /Quick start quality/ }).click();
  await expect(page.getByRole('heading', { name: 'Quick start quality' })).toBeVisible();
  await page.getByRole('link', { name: 'Inbox', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: "You're all caught up" })).toBeVisible();
  await accessible(page);
  await capture(page, 'inbox-Daylight');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('navigation', { name: 'Workspace navigation' }).getByRole('link', { name: 'Home' }).click();
  await accessible(page);
  await capture(page, 'home-mobile');
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
  const chooserOpened = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose images', exact: true }).click();
  const chooser = await chooserOpened;
  await chooser.setFiles({
    name: 'pixel.png', mimeType: 'image/png',
    buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4WQAAAAASUVORK5CYII=', 'base64'),
  });
  await expect(page.locator('.workspace-upload')).toContainText('pixel.png');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.locator('.workspace-upload')).toHaveCount(0);
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Draft survives reconnect' }).locator('.md')).toContainText('There is one TODO worth doing here');
  await capture(page, 'track-Ravix');
  await chooseTheme(page, 'Daylight');
  await accessible(page);
  await capture(page, 'track-Daylight');
  await page.setViewportSize({ width: 390, height: 844 });
  await accessible(page);
  await capture(page, 'track-mobile');
  await page.setViewportSize({ width: 1280, height: 720 });
  // The same session is revoked from a second tab while the first remains connected.
  const trackURL = page.url();
  await composer.fill("This must never be sent");
  const other = await context.newPage();
  await other.goto('/home');
  await other.getByRole('link', { name: 'Sign out' }).click();
  await expect(other.getByRole('link', { name: 'Sign in', exact: true })).toBeVisible();
  await page.evaluate(() => document.querySelector("#composer-form")?.requestSubmit());
  await expect(page.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
  await signIn(page);
  await page.goto(trackURL);
  await expect(page.locator("#transcript-turns")).toBeVisible();
  await expect(page.locator("#transcript-turns")).not.toContainText("This must never be sent");
  await page.screenshot({ path: test.info().outputPath("workspace.png"), fullPage: true });
  expect(errors).toEqual([]);
});
