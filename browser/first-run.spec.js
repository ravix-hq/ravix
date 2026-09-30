import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

// RAV-41: a new person connects an agent and types their first request within
// a minute, and sees it start. The whole path through the mock, as somebody
// nobody has signed in as before: how it works, one agent, GitHub, the first
// prompt, and the track it opened with that prompt waiting for setup.

async function accessible(page) {
  const axe = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);
}

async function connected(page) {
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
}

test('a new person goes from welcome to a track with their first prompt waiting', async ({ page }) => {
  test.setTimeout(120_000);
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
  await page.getByRole('link', { name: 'Sign in as @firstrun', exact: true }).click();
  await expect(page).toHaveURL(/\/welcome$/);
  await connected(page);

  // How it works is drawn with its own rules, not as bare disclosure widgets:
  // a flex column of bordered, numbered steps with no default marker.
  const workflow = page.locator('#welcome-workflow');
  await expect(workflow).toBeVisible();
  const styles = await workflow.evaluate((section) => {
    const step = section.querySelector('details');
    const summary = step.querySelector('summary');
    const num = step.querySelector('.workflow-num');
    return {
      display: getComputedStyle(section).display,
      stepBorder: getComputedStyle(step).borderTopStyle,
      summaryDisplay: getComputedStyle(summary).display,
      numRadius: parseFloat(getComputedStyle(num).borderTopLeftRadius),
      prompt: getComputedStyle(step.querySelector('.example-prompt')).borderTopLeftRadius,
    };
  });
  expect(styles).toMatchObject({ display: 'flex', stepBorder: 'solid', summaryDisplay: 'flex' });
  expect(styles.numRadius).toBeGreaterThan(0);
  expect(styles.prompt).not.toBe('0px');
  await page.locator('summary', { hasText: 'Review the work' }).click();
  await expect(page.getByText('The diff sits next to the conversation.', { exact: false })).toBeVisible();
  await accessible(page);

  // Your agent: one decision.
  await page.getByRole('link', { name: 'Set up your agent', exact: true }).click();
  await expect(page).toHaveURL(/\/welcome\/agent$/);
  await connected(page);
  await expect(page.locator('#agent-manage')).toBeHidden();
  await expect(page.locator('#thread-default-form')).toBeHidden();
  await expect(page.getByRole('link', { name: "I'll do this later", exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
  await page.getByLabel('Subscription token', { exact: true }).fill('sk-ant-oat01-browser-fixture');
  await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
  await expect(page.locator('#agent-claude-status')).toContainText('Connected');
  // The first connection is the default without being asked.
  await expect(page.locator('#agent-claude-status')).toContainText('Default for new projects');
  await accessible(page);
  await page.getByRole('link', { name: 'Continue', exact: true }).click();

  // GitHub, unchanged.
  await expect(page).toHaveURL(/\/welcome\/github$/);
  await connected(page);
  await expect(page.locator('#github-connected')).toBeVisible();
  await page.locator('#github-continue').click();

  // The first prompt: a repository, what to do, and Start. The agent is the
  // default just made, as a chip.
  await expect(page).toHaveURL(/\/welcome\/project$/);
  await connected(page);
  await expect(page.getByRole('heading', { name: 'What do you want to work on?' })).toBeVisible();
  await expect(page.locator('#first-prompt-runtime')).toHaveValue('claude');
  const target = page.getByLabel('Repository', { exact: true });
  await expect(target.locator('option[value="repo:mockuser/atlas-api"]')).toBeAttached();
  await target.selectOption('repo:mockuser/atlas-api');
  const prompt = page.getByLabel('What do you want to work on in mockuser/atlas-api?', { exact: true });
  await page.getByRole('button', { name: 'Explain how this codebase is organized', exact: true }).click();
  await expect(prompt).toHaveValue('Explain how this codebase is organized');
  await prompt.fill('Add a health check endpoint');
  await accessible(page);
  await page.getByRole('button', { name: 'Start', exact: true }).click();

  // Straight into the track: its setup steps, and the prompt waiting for them.
  await expect(page).toHaveURL(/\/p\/[^/]+\/t\/[^/?]+$/, { timeout: 60_000 });
  await connected(page);
  const queue = page.locator('.workspace-queue');
  await expect(queue).toContainText('Add a health check endpoint');
  await expect(queue).toContainText('Starts when setup is ready');
  await expect(page.locator('#track-setup-steps')).toBeVisible();
  await expect(page.locator('#track-setup-steps li')).toHaveCount(4);

  // And once setup is ready the prompt is the thread's first message; see
  // first-prompt.spec.js for why each wait allows a full queue sweep.
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 60_000 });
  await expect(page.locator('#transcript-turns .workspace-prompt')
    .filter({ hasText: 'Add a health check endpoint' })).toHaveCount(1, { timeout: 45_000 });

  // Finishing the walkthrough by starting: the workspace does not send them back.
  await page.goto('/');
  await expect(page).not.toHaveURL(/\/welcome/);
});
