import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openRepositories, openAddRepository } from './new-track.js';
import { draftChoice, newThread } from './draft-runtime.js';

test('conversation tabs, project picker, settings gears and inspector at desktop and 500px', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  const projects = [];
  for (const name of ['Layout alternate', 'Layout current']) {
    await openAddRepository(page);
    const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
    await dialog.getByLabel('Project name', { exact: true }).fill(name);
    await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
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
    await newThread(page);
    const draft = page.locator('#draft-runtime');
    await expect(draftChoice(page, 'runtime')).toHaveValue('claude');
    // Long enough that four title-only tabs (RAV-82) still overrun the row:
    // a thread is titled with its first message's first five words.
    await composer.fill(`Layout thread ${i + 1} overflowing horizontally`);
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
      // Beside the conversation the threads stand on end, one under another.
      await expect(page.locator('#thread-tablist')).toHaveAttribute('aria-orientation', 'vertical');
      const tops = await tabs.evaluateAll(els => els.map(el => el.getBoundingClientRect().top));
      expect(tops.every((top, i) => i === 0 || top > tops[i - 1]), `tab tops ${tops}`).toBe(true);
      await tabs.last().press('ArrowDown');
      await expect(tabs.first()).toBeFocused();
      await tabs.first().press('ArrowUp');
      await expect(tabs.last()).toBeFocused();
      await tabs.last().press('ArrowRight');
      await expect(tabs.first()).toBeFocused();
      await tabs.first().press('Enter');
      await expect(tabs.first()).toHaveAttribute('aria-selected', 'true');
      // The track's own tabs name the inspector's panels; the inspector
      // keeps only its tools, and takes the page's width in place of the
      // conversation rather than sitting beside it.
      const views = page.getByRole('navigation', { name: 'Track views' });
      await expect(views.getByRole('button')).toHaveText([/Threads\s*4/, 'Files', 'Changes', 'Checks', 'Preview', 'Terminal']);
      await expect(page.locator('#inspector')).toBeHidden();
      await page.locator('#track-tab-files').click();
      await expect(page.locator('#track-tab-files')).toHaveAttribute('aria-pressed', 'true');
      await expect(page.locator('#inspector .workspace-panel')).toBeVisible();
      await expect(page.locator('.track-conversation')).toBeHidden();
      await expect(page.getByRole('navigation', { name: 'Inspector panels' }).locator('[phx-click=panel]')).toHaveCount(4);
      await expect(page.getByRole('navigation', { name: 'Inspector panels' }).locator('[phx-click=panel]').first()).toBeHidden();
      await page.locator('#track-tab-threads').click();
      await expect(page.locator('#track-tab-threads')).toHaveAttribute('aria-pressed', 'true');
      await expect(page.locator('#inspector')).toBeHidden();
      await expect(page.locator('.track-conversation')).toBeVisible();
    } else {
      await expect(tabs.first()).not.toBeVisible();
      await expect(page.getByLabel('Thread', { exact: true })).toBeVisible();
      await page.getByLabel('Thread', { exact: true }).selectOption(firstId);
      await expect(page.locator(`#composer-${firstId}`)).toBeVisible();
      await page.locator('#track-tab-files').click();
      await expect(page.locator('#inspector .workspace-panel')).toBeVisible();
      await expect(page.locator('.track-conversation')).toBeHidden();
      await page.locator('#track-tab-threads').click();
      await expect(page.locator('.track-conversation')).toBeVisible();
    }
    // The top bar's project crumb leads to the project's page, whose
    // Settings tab opens its settings.
    const crumb = page.locator('#topbar .topbar-crumbs a[href^="/p/"]');
    await expect(crumb).toHaveAttribute('href', `/p/${projects[1]}`);
    await crumb.click();
    const settingsTab = page.locator('#crumb-settings');
    await settingsTab.focus();
    await expect(settingsTab).toBeVisible();
    await settingsTab.click();
    // Settings are a page in the shell (RAV-72); Back returns the way it came.
    await expect(page).toHaveURL(/\/settings\/general$/);
    await expect(page.locator('#settings-page')).toBeVisible();
    await page.goBack();
    await expect(page).toHaveURL(new RegExp(`/p/${projects[1]}$`));
    await page.goBack();
    await expect(page).toHaveURL(trackUrl);
    await expect(page.locator('#track-header')).toBeVisible();
    await page.getByRole('button', { name: 'You', exact: true }).click();
    await expect(page.locator('#account-menu')).toBeVisible();
    await page.keyboard.press('Escape');
    await page.locator('#top-new-track').click();
    await newTrack.getByRole('button', { name: 'Options', exact: true }).click();
    await newTrack.getByLabel('Branch name').fill('keep-my-draft');
    await openRepositories(newTrack);
    await expect(newTrack.getByLabel('Project / repository')).toHaveValue(projects[1]);
    await newTrack.getByLabel('Project / repository').selectOption(projects[0]);
    await expect(newTrack.getByLabel('Branch name')).toHaveValue('keep-my-draft');
    await expect(newTrack.getByLabel('Project / repository')).toHaveValue(projects[0]);
    // Escape closes the repository popover first, then the dialog.
    await page.keyboard.press('Escape');
    await expect(newTrack.locator('#new-track-repo-menu')).toBeHidden();
    await expect(page).toHaveURL(trackUrl);
    await expect(page.locator('#topbar .topbar-crumbs a[href^="/p/"]')).toHaveAttribute('href', `/p/${projects[1]}`);
    await page.keyboard.press('Escape');
    await expect(page).toHaveURL(trackUrl);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  }
});
