import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// Every word the header chip says, in order, as the page draws it. Opening
// and a mock turn can each finish between two polls, so the page records
// its own transitions rather than the test sampling them.
function recordChip() {
  window.__machineStates = [];
  new MutationObserver(() => {
    const chip = document.getElementById('track-machine-state');
    const word = chip && chip.textContent.trim();
    const seen = window.__machineStates;
    if (word && seen[seen.length - 1] !== word) seen.push(word);
  }).observe(document, { subtree: true, childList: true, characterData: true });
}

for (const width of [1280, 500]) {
  test(`a new track's machine state goes Starting, Idle, Working, Idle at ${width}px`, async ({ page }) => {
    test.setTimeout(120_000);
    await page.addInitScript(recordChip);
    await signIn(page, 'eli', '/home');
    await connectClaude(page);
    await page.getByRole('button', { name: /^New project/ }).first().click();
    await page.getByLabel('Project name', { exact: true }).fill(`Machine state ${width}`);
    await page.getByRole('button', { name: 'Create project', exact: true }).click();
    // The track is opened, and watched, at the width under test.
    await page.setViewportSize({ width, height: 900 });
    if (width < 760) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    await page.locator('#yard .workspace-project.current .project-add').click();
    await page.getByRole('button', { name: 'Create track', exact: true }).click();

    const chip = page.locator('#track-machine-state');
    await expect(chip).toHaveAttribute('role', 'status');
    await expect(chip).toHaveAttribute('aria-live', 'polite');
    await expect(chip).toHaveText('Idle', { timeout: 30_000 });
    await expect(page.locator('#track-machine-status')).toHaveText('Idle.');
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

    const composer = page.getByRole('textbox', { name: 'Message', exact: true });
    await expect(composer).toBeEnabled();
    const prompt = `Explain this project at ${width}px`;
    await composer.fill(prompt);
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(chip).toHaveText('Working', { timeout: 20_000 });
    await expect(chip).toHaveAttribute('title', 'The agent is taking a turn.');
    if (width < 760) await page.getByRole('button', { name: 'Menu', exact: true }).click();
    const row = page.locator('#yard .workspace-project.current .workspace-track[aria-current=page]');
    await expect(row).toHaveAttribute('aria-label', /, Working/);
    await expect(row.locator('.dot.working')).toBeVisible();
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    // Choosing the row closes the drawer, as it does for any track.
    if (width < 760) await row.click();
    await expect(page.locator('.workspace-turn').filter({ hasText: prompt }).locator('.agent-terminal-output')).toContainText('There is one TODO worth doing here', { timeout: 20_000 });
    await expect(chip).toHaveText('Idle', { timeout: 20_000 });

    const seen = await page.evaluate(() => window.__machineStates);
    expect(seen.slice(0, 1)).toEqual(['Starting']);
    expect(seen.slice(-3)).toEqual(['Idle', 'Working', 'Idle']);
    expect(seen.filter(word => !['Starting', 'Idle', 'Working'].includes(word))).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: `tmp/machine-state-${width}.png` });
  });
}
