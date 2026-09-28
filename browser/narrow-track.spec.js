import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';

// Count the visible vertical scroll surfaces, including empty panes: a short
// fixture must not hide a second scroll container that real content would fill.
async function scrollSurfaces(page) {
  return page.locator('.split, .track-conversation, .transcript-scroll, .workspace-panel, .term-scroll, .track-plan-list').evaluateAll(elements =>
    elements.filter(el => el.getClientRects().length && ['auto', 'scroll'].includes(getComputedStyle(el).overflowY)).length);
}

test('narrow track views give the conversation space and preserve drafts', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('Narrow track');
  const repository = page.getByLabel('Repository', { exact: true });
  await expect(page.locator('#project-repositories option')).not.toHaveCount(0);
  await repository.fill('mockuser/atlas-api');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled();
  await expect(page.locator('#transcript-status')).toHaveText('Agent replied');
  // Saving a prompt wakes the queue worker, so each goes out on Send.
  for (let turn = 0; turn < 3; turn++) {
    const prompt = `Explain this project, narrow turn ${turn}`;
    await composer.fill(prompt);
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(page.locator('.workspace-turn').filter({ hasText: prompt }).locator('.agent-terminal-output')).toContainText('There is one TODO worth doing here', { timeout: 20_000 });
  }
  await composer.fill('Keep this conversation draft');
  const views = page.getByRole('navigation', { name: 'Track views', exact: true });
  for (const width of [400, 535, 600]) {
    await page.setViewportSize({ width, height: 900 });
    await views.getByRole('button', { name: 'Conversation', exact: true }).click();
    await expect(views.getByRole('button', { name: 'Conversation', exact: true })).toHaveAttribute('aria-pressed', 'true');
    expect((await page.locator('.track-conversation').boundingBox()).height).toBeGreaterThan(600);
    expect((await page.locator('.transcript-scroll').boundingBox()).height).toBeGreaterThan(400);
    expect(await scrollSurfaces(page)).toBe(1);
    expect(await page.locator('.transcript-scroll').evaluate(el => el.scrollHeight > el.clientHeight)).toBe(true);
    await expect(page.getByRole('complementary', { name: 'Track inspector' })).toBeHidden();
    await page.screenshot({ path: `tmp/narrow-conversation-${width}.png` });
    await views.getByRole('button', { name: 'Files', exact: true }).click();
    await expect(page.getByRole('navigation', { name: 'Inspector panels' })).toBeVisible();
    await expect(composer).toBeHidden();
    expect(await scrollSurfaces(page)).toBe(1);
    await page.screenshot({ path: `tmp/narrow-files-${width}.png` });
    await views.getByRole('button', { name: 'Commands', exact: true }).click();
    const command = page.getByRole('textbox', { name: 'Command', exact: true });
    await expect(command).toBeVisible();
    await page.getByRole('button', { name: 'Open Run', exact: true }).click();
    await expect(views.getByRole('button', { name: 'Files', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByRole('navigation', { name: 'Inspector panels' })).toBeVisible();
    await expect(page.getByRole('navigation', { name: 'Inspector panels' }).getByRole('button', { name: 'Run', exact: true })).toHaveClass('selected');
    await views.getByRole('button', { name: 'Commands', exact: true }).click();
    await command.fill('echo preserved');
    expect(await scrollSurfaces(page)).toBe(1);
    await page.screenshot({ path: `tmp/narrow-terminal-${width}.png` });
    await views.getByRole('button', { name: 'Conversation', exact: true }).click();
    await expect(composer).toHaveValue('Keep this conversation draft');
    await views.getByRole('button', { name: 'Commands', exact: true }).click();
    await expect(command).toHaveValue('echo preserved');
    const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
    expect(result.violations).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
  await page.setViewportSize({ width: 1480, height: 900 });
  await expect(views).toBeHidden();
  await expect(composer).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Inspector panels' })).toBeVisible();
});
