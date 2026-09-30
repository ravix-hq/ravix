import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';

// RAV-77: the person's own settings, each a page on the settings frame, and
// the You menu that opens them. Its own login, because the last test signs
// it out everywhere.
const login = 'personalsettings';

async function accessible(page) {
  await page.evaluate(() => Promise.all(document.getAnimations()
    .filter(a => a.effect?.getTiming?.().iterations !== Infinity)
    .map(a => a.finished.catch(() => {}))));
  const result = await new AxeBuilder({ page }).include('#settings-page')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(result.violations.map(v => `${v.id}: ${v.nodes.map(n => n.target.join(' ')).join(', ')}`)).toEqual([]);
}

test('the You menu opens Settings, and every personal page is a section of the frame', async ({ page }) => {
  await signIn(page, login, '/home');
  const trigger = page.locator('#account-trigger');
  const menu = page.locator('#account-menu');
  await trigger.click();
  // Quick toggles, then a short menu.
  await expect(menu.locator('#theme-picker [data-theme-toggle]')).toBeVisible();
  await expect(menu.locator('#notify [data-notify-toggle]')).toBeVisible();
  await expect(menu.locator('.account-item')).toHaveText(['Settings', 'Help', "What's new", 'Sign out']);
  await menu.getByRole('button', { name: 'Settings', exact: true }).click();
  await expect(menu).toBeHidden();
  await expect(page).toHaveURL(/\/settings\/profile$/);

  const nav = page.getByRole('navigation', { name: 'Settings sections' });
  await expect(nav.locator('.settings-group').first().getByRole('link')).toHaveText([
    'Profile', 'Agents', 'Notifications', 'Appearance', 'Connected apps',
  ]);

  const pages = [
    ['profile', 'Profile'], ['agents', 'Agents'], ['notifications', 'Notifications'],
    ['appearance', 'Appearance'], ['connected-apps', 'Connected apps'],
  ];
  for (const [key, label] of pages) {
    await nav.getByRole('link', { name: label, exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`/settings/${key}$`));
    await expect(page).toHaveTitle(`${label} · You · Ravix`);
    await expect(page.getByRole('heading', { level: 1, name: label, exact: true })).toBeVisible();
    await expect(page.locator('#yard')).toBeVisible();
    await expect(page.locator('#settings-page .agent-card-status', { hasText: 'Checking' })).toHaveCount(0);
    await accessible(page);
  }
  // Browser back and forward move between them.
  await page.goBack();
  await expect(page).toHaveURL(/\/settings\/appearance$/);

  // Profile is GitHub's identity, read-only.
  await page.goto('/settings/profile');
  await expect(page.locator('#profile-name')).toHaveText('Personal Settings');
  await expect(page.locator('#profile-login')).toHaveText(`@${login}`);
  await expect(page.locator('#settings-profile input')).toHaveCount(0);
});

test('Appearance and the menu\'s theme toggle are one choice, kept by this browser', async ({ page }) => {
  await signIn(page, login, '/settings/appearance');
  const picker = page.locator('#appearance-theme');
  await picker.locator('[data-theme-toggle]').click();
  // The list opens below its trigger, inside the page.
  const list = picker.getByRole('menu', { name: 'Theme' });
  await expect(list).toBeVisible();
  const trigger = await picker.locator('[data-theme-toggle]').boundingBox();
  const box = await list.boundingBox();
  expect(box.y).toBeGreaterThan(trigger.y);
  await accessible(page);
  await list.getByRole('menuitemradio', { name: 'Daylight', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
  await expect(picker.locator('[data-theme-toggle] [data-theme-name]')).toHaveText('Daylight');
  // The menu's quick toggle says the same, without a reload.
  await expect(page.locator('#account-menu #theme-picker [data-theme-toggle] [data-theme-name]')).toHaveText('Daylight');

  await page.locator('#account-trigger').click();
  await page.locator('#account-menu [data-theme-toggle]').click();
  await page.locator('#account-menu').getByRole('menuitemradio', { name: 'Ravix', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'ravix');
  await expect(picker.locator('[data-theme-toggle] [data-theme-name]')).toHaveText('Ravix');
  await page.keyboard.press('Escape');

  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'ravix');
});

test('Notifications is the desktop switch, the same as the menu\'s, and says what reaches the Inbox', async ({ page }) => {
  await signIn(page, login, '/settings/notifications');
  // Headless Chromium has no desktop notifications to give; this stands in
  // for the browser's API, as `assets/test/notify.test.js` does.
  await page.evaluate(() => {
    window.Notification = class { static permission = 'default'; static requestPermission() { this.permission = 'granted'; return Promise.resolve('granted'); } };
  });
  await page.evaluate(() => window.dispatchEvent(new CustomEvent('ravix:notify-changed')));
  const toggle = page.locator('#notify-setting [data-notify-toggle]');
  const quick = page.locator('#account-menu #notify [data-notify-toggle]');
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-pressed', 'true');
  await expect(toggle).toContainText('On');
  await expect(quick).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#settings-inbox')).toContainText('What reaches your Inbox');
  await expect(page.locator('#settings-inbox li')).toHaveCount(4);
  await accessible(page);

  await page.locator('#account-trigger').click();
  await quick.click();
  await expect(quick).toHaveAttribute('aria-pressed', 'false');
  await expect(toggle).toHaveAttribute('aria-pressed', 'false');
});

test('Sign out everywhere ends every browser\'s session after asking', async ({ page, browser }) => {
  await signIn(page, login, '/settings/profile');
  const other = await browser.newContext();
  const elsewhere = await other.newPage();
  try {
    await signIn(elsewhere, login, '/home');

    // Declining the question changes nothing.
    page.once('dialog', dialog => dialog.dismiss());
    await page.getByRole('button', { name: 'Sign out everywhere', exact: true }).click();
    await expect(page).toHaveURL(/\/settings\/profile$/);

    page.once('dialog', dialog => {
      expect(dialog.message()).toContain('every browser');
      dialog.accept();
    });
    await page.getByRole('button', { name: 'Sign out everywhere', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
    // The other browser is told at once, and lands on sign-in too.
    await expect(elsewhere.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
    await page.goto('/settings/profile');
    await expect(page).toHaveURL(/\/login$/);
  } finally {
    await other.close();
  }
});
