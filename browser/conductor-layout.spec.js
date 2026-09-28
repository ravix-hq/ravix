import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

test('conversation tabs, project picker, settings gears and inspector at desktop and 500px', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  const projects = [];
  for (const name of ['Layout alternate', 'Layout current']) {
    await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
    const dialog = page.getByRole('dialog', { name: 'New project', exact: true });
    await dialog.getByLabel('Project name', { exact: true }).fill(name);
    await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
    await expect(dialog).not.toBeVisible();
    projects.push(new URL(page.url()).pathname.split('/')[2]);
  }
  await page.locator('#top-new-track').click();
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await expect(newTrack.getByLabel('Project / repository')).toHaveValue(projects[1]);
  await newTrack.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(newTrack).not.toBeVisible();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  for (let i = 0; i < 3; i++) {
    await page.getByRole('button', { name: 'Add thread', exact: true }).click();
    const draft = page.locator('#draft-runtime');
    await expect(draft.getByLabel('Agent', { exact: true })).toHaveValue('claude');
    await composer.fill(`Layout thread ${i + 1}`);
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(draft).not.toBeVisible();
    await expect(page.locator('#thread-tab-draft')).toHaveCount(0);
  }
  // The last send named its thread in the URL. Dialogs opened below patch the
  // query, so what they must not move is the track.
  await expect(page).toHaveURL(/\?thread=/);
  const trackUrl = new RegExp(`${new URL(page.url()).pathname}(\\?thread=[0-9a-f-]+)?$`);
  const tabs = page.locator('.thread-tab');
  await expect(tabs).toHaveCount(4);
  const firstId = await tabs.first().getAttribute('data-thread-id');
  for (const width of [1280, 500]) {
    await page.setViewportSize({ width, height: 900 });
    if (width === 1280) {
      await expect(page.locator('#thread-picker')).not.toBeVisible();
      await tabs.first().focus();
      await tabs.first().press('End');
      await expect(tabs.last()).toBeFocused();
      await expect(page.locator('[role=tab][tabindex="0"]')).toHaveCount(1);
      await expect(tabs.last()).toHaveAttribute('tabindex', '0');
      expect(await page.locator('#thread-switcher').evaluate(el => el.scrollLeft)).toBeGreaterThan(0);
      await tabs.last().press('ArrowRight');
      await expect(tabs.first()).toBeFocused();
      await tabs.first().press('Enter');
      await expect(tabs.first()).toHaveAttribute('aria-selected', 'true');
      const panels = page.getByRole('navigation', { name: 'Inspector panels' });
      await expect(panels.locator('[phx-click=panel]')).toHaveText(['Files', 'Changes', 'Checks', 'Preview']);
      await page.locator('#inspector-toggle').click();
      await expect(page.locator('#inspector-toggle')).toHaveAttribute('aria-expanded', 'false');
      await expect(page.locator('#inspector .workspace-panel')).not.toBeVisible();
      await page.locator('#inspector-toggle').click();
      await expect(page.locator('#inspector .workspace-panel')).toBeVisible();
    } else {
      await expect(tabs.first()).not.toBeVisible();
      await expect(page.getByLabel('Thread', { exact: true })).toBeVisible();
      await page.getByLabel('Thread', { exact: true }).selectOption(firstId);
      await expect(page.locator(`#composer-${firstId}`)).toBeVisible();
      await page.getByRole('button', { name: 'Files', exact: true }).click();
      await expect(page.getByRole('navigation', { name: 'Inspector panels' })).toBeVisible();
      await page.getByRole('button', { name: 'Conversation', exact: true }).click();
      await page.getByRole('button', { name: 'Menu', exact: true }).click();
    }
    await page.locator('.workspace-project.current .workspace-project-row').hover();
    const gear = page.locator('.workspace-project.current button[title="Project settings"]');
    await gear.focus();
    await expect(gear).toHaveCSS('opacity', '1');
    await gear.click();
    await expect(page.getByRole('dialog', { name: 'Project settings', exact: true })).toBeVisible();
    await page.keyboard.press('Escape');
    if (width === 500) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    await page.getByRole('button', { name: 'Account and app settings', exact: true }).click();
    await expect(page.locator('#account-menu')).toBeVisible();
    await page.keyboard.press('Escape');
    if (width === 500) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    await page.locator('#top-new-track').click();
    await expect(newTrack.getByLabel('Project / repository')).toHaveValue(projects[1]);
    await newTrack.getByRole('button', { name: 'Advanced', exact: true }).click();
    await newTrack.getByLabel('Branch name').fill('keep-my-draft');
    await newTrack.getByLabel('Project / repository').selectOption(projects[0]);
    await expect(newTrack.getByLabel('Branch name')).toHaveValue('keep-my-draft');
    await expect(newTrack.getByLabel('Project / repository')).toHaveValue(projects[0]);
    await expect(page).toHaveURL(trackUrl);
    await expect(page.locator('.workspace-project.current')).toHaveAttribute('data-project-id', projects[1]);
    await page.keyboard.press('Escape');
    await expect(page).toHaveURL(trackUrl);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  }
});
