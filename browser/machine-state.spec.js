import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

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
    await openAddRepository(page);
    await page.getByLabel('Project name', { exact: true }).fill(`Machine state ${width}`);
    await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
    // The track is opened, and watched, at the width under test.
    await page.setViewportSize({ width, height: 900 });
    await page.locator('#top-new-track').click();
    await page.getByRole('button', { name: 'Create track', exact: true }).click();

    const chip = page.locator('#track-machine-state');
    await expect(chip).toHaveAttribute('role', 'status');
    await expect(chip).toHaveAttribute('aria-live', 'polite');
    await expect(chip).toHaveText('Idle', { timeout: 30_000 });
    // The status line's pill draws every state, Idle included, in words.
    await expect(chip).toBeVisible();
    await expect(chip).not.toHaveClass(/sr-only/);
    await expect(page.locator('#track-header .track-head-status #track-machine-state')).toHaveCount(1);
    // The chip is the one live region for the machine's state.
    await expect(page.locator('#track-machine-status')).toHaveCount(0);
    await expect(page.locator('.machine-dock-host > [role=status]')).toHaveCount(0);
    const scope = page.locator('#track-machine-scope');
    await expect(scope).toHaveText('Shared machine');
    await expect(scope).toHaveAttribute('title', "Used by all of this project's tracks");
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

    // The project's page, in a second tab at the same width, lists the
    // track and says the same word as the header.
    const [projectPath, trackId] = new URL(page.url()).pathname.split('/t/');
    const list = await page.context().newPage();
    await list.setViewportSize({ width, height: 900 });
    await list.goto(projectPath);
    await expect(list.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await list.locator('#project-tracks-list').click();
    const row = list.locator(`#tracks-row-${trackId}`);
    await expect(row.locator('.tracks-row-state')).toHaveText('Idle');

    const composer = page.getByRole('textbox', { name: 'Message', exact: true });
    await expect(composer).toBeEnabled();
    const prompt = `Explain this project at ${width}px`;
    await composer.fill(prompt);
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    await expect(chip).toHaveText('Working', { timeout: 20_000 });
    await expect(chip).toHaveAttribute('data-tip', 'The agent is taking a turn.');
    await expect(row.locator('.tracks-row-state')).toHaveText('Working');
    await expect(row.locator('.dot')).toHaveAttribute('aria-label', /(^| · )Working$/);
    // Home's Active tracks says it too, at every width (the sidebar's Active
    // tracks that said so is gone).
    const home = await page.context().newPage();
    await home.setViewportSize({ width, height: 900 });
    await home.goto('/home');
    await expect(home.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    const active = home.locator(`#home-side #home-active-${trackId}`);
    await expect(active).toBeVisible();
    await expect(active).toHaveAttribute('href', `${projectPath}/t/${trackId}`);
    await expect(active.locator('.dot')).toHaveAttribute('aria-label', /(^| · )Working$/);
    await home.close();
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    expect((await new AxeBuilder({ page: list }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    await expect(page.locator('.workspace-turn').filter({ hasText: prompt }).locator('.agent-terminal-output')).toContainText('There is one TODO worth doing here', { timeout: 20_000 });
    await expect(chip).toHaveText('Idle', { timeout: 20_000 });
    await list.close();

    const seen = await page.evaluate(() => window.__machineStates);
    expect(seen.slice(0, 1)).toEqual(['Starting']);
    expect(seen.slice(-3)).toEqual(['Idle', 'Working', 'Idle']);
    expect(seen.filter(word => !['Starting', 'Idle', 'Working'].includes(word))).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: `tmp/machine-state-${width}.png` });
  });
}
