import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-47: the New track dialog takes an optional first prompt. Enter creates
// the track, and the prompt waits in its queue until setup is ready.
test('a first prompt typed in the create dialog opens the track with it waiting for setup', async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('First prompt');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();

  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  const prompt = dialog.getByLabel('What do you want to work on?', { exact: true });
  await expect(prompt).toBeVisible();
  await expect(dialog.getByRole('button', { name: 'Create track', exact: true })).toBeEnabled();
  await prompt.fill('Add a **health check** endpoint');
  // Shift+Enter is a new line, not a submit.
  await prompt.press('Shift+Enter');
  await prompt.pressSequentially('and document it');
  await expect(prompt).toHaveValue('Add a **health check** endpoint\nand document it');
  // RAV-61: a prompt is markdown, fences included. This line is far wider
  // than the bubble, which must scroll it rather than grow to fit it.
  const wide = `curl -fsS http://localhost:4000/health${'?probe=1'.repeat(40)}`;
  await prompt.fill(`Add a **health check** endpoint\nand document it\n\n\`\`\`sh\n${wide}\n\`\`\``);
  await expect(dialog).toBeVisible();
  const axe = await new AxeBuilder({ page }).include('#new-track-dialog')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);

  await prompt.press('Enter');
  await expect(dialog).toHaveCount(0);
  const queue = page.locator('.workspace-queue');
  await expect(queue).toContainText('Add a health check endpoint');
  await expect(queue.locator('.queue-prompt strong')).toHaveText('health check');
  await expect(queue.locator('.chip')).toHaveText('Waiting');
  await expect(page.locator('#track-setup-status')).toContainText('Prompts will wait until setup is ready.');

  // Once setup is ready the queue delivers it as the thread's first message.
  // Setup's later checks and the delivery ride the queue's sweep, whose
  // backstop is thirty seconds, so each wait allows a full sweep and more.
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 60_000 });
  await expect(queue).toHaveCount(0, { timeout: 45_000 });
  const delivered = '#transcript-turns .workspace-turn > .said > .workspace-prompt';
  const bubble = page.locator(delivered).filter({ hasText: 'Add a health check endpoint' });
  await expect(bubble).toHaveCount(1, { timeout: 20_000 });
  await expect(bubble.locator('strong')).toHaveText('health check');
  // The typed newline is a break, not a space.
  await expect(bubble.locator('p br')).toHaveCount(1);
  await expect(bubble.locator('pre code')).toHaveText(wide);
  // Each patch to the running turn replaces its `.said`, so a handle resolved
  // before one is detached by the time it is measured (RAV-78). Find and
  // measure in one synchronous call, which no patch can interrupt.
  const fit = await page.evaluate(({ delivered, text }) => {
    const [el, ...rest] = [...document.querySelectorAll(delivered)]
      .filter(bubble => bubble.textContent.includes(text));
    if (!el || rest.length) return null;
    const pre = el.querySelector('pre');
    return {
      bubble: el.getBoundingClientRect().width,
      column: el.closest('.said').getBoundingClientRect().width,
      turn: el.closest('.workspace-turn').getBoundingClientRect().width,
      scrolls: pre.scrollWidth > pre.clientWidth,
      overflow: getComputedStyle(pre).overflowX,
    };
  }, { delivered, text: 'Add a health check endpoint' });
  expect(fit).not.toBeNull();
  expect(fit.bubble).toBeLessThanOrEqual(fit.column + 0.5);
  expect(fit.column).toBeLessThanOrEqual(fit.turn * 0.8 + 0.5);
  expect(fit.scrolls).toBe(true);
  expect(fit.overflow).toBe('auto');
});
