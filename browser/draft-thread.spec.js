import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-30: "+" adds a draft tab on the person's default agent and model; the
// first message creates the thread and sends that prompt as one step.
test('a draft thread becomes a real thread with its first message running, wide and narrow', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Draft threads');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'New track', exact: true })).toHaveCount(0);
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  const tabs = page.getByRole('navigation', { name: 'Threads', exact: true });
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  const accessible = async () => {
    const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
    expect(axe.violations).toEqual([]);
  };

  for (const [width, prompt] of [
    [1280, 'Summarise the repository layout and point out anything unusual'],
    [500, 'Narrow screens start threads too'],
  ]) {
    await page.setViewportSize({ width, height: 900 });
    await expect(composer).toBeEnabled({ timeout: 30_000 });
    await tabs.getByRole('button', { name: 'Add thread', exact: true }).click();
    const draft = page.locator('#draft-runtime');
    await expect(page.locator('#new-thread-dialog')).toHaveCount(0);
    await expect(page.locator('#draft-thread-empty')).toContainText('Your first message starts this thread.');
    await expect(draft.getByLabel('Agent', { exact: true })).toHaveValue('claude');
    if (width === 1280) {
      await expect(tabs.locator('#thread-tab-draft')).toHaveAttribute('aria-selected', 'true');
      await expect(tabs.locator('#thread-tab-draft')).toContainText('New thread');
    } else {
      await expect(tabs.locator('#thread-tablist')).toBeHidden();
      await expect(page.locator('#thread-picker option:checked')).toHaveText(/^New thread/);
    }
    await accessible();
    // Change the model: the draft names the new one before anything is sent.
    const models = draft.getByLabel('Model', { exact: true });
    const current = await models.inputValue();
    const values = await models.locator('option').evaluateAll(nodes => nodes.map(n => n.value));
    const next = values.find(value => value !== current);
    expect(next).toBeTruthy();
    await models.selectOption(next);
    const label = (await models.locator(`option[value="${next}"]`).textContent()).trim();
    await expect(page.locator('#thread-picker option[value="draft"]')).toContainText(label);
    await composer.fill(prompt);
    await page.getByRole('button', { name: 'Send', exact: true }).click();
    // One step: the draft is gone, a real thread is selected, the URL names
    // it, and its first prompt is the turn that runs.
    await expect(draft).toHaveCount(0);
    await expect(page.locator('#thread-tab-draft')).toHaveCount(0);
    const selected = tabs.locator('.thread-tab[aria-selected="true"]');
    await expect(selected).not.toHaveAttribute('data-thread-id', 'draft');
    const threadId = await selected.getAttribute('data-thread-id');
    await expect(page).toHaveURL(new RegExp(`\\?thread=${threadId}$`));
    // RAV-48: titled by the prompt's key phrase, not the prompt cut short.
    const title = width === 1280 ? 'Summarise Repository Layout' : 'Narrow Screens Start Threads Too';
    await expect(page.locator('#thread-picker option:checked')).toContainText(title);
    await expect(page.locator('#transcript-turns .workspace-prompt').filter({ hasText: prompt })).toHaveCount(1, { timeout: 20_000 });
    await expect(page.locator('.workspace-turn').filter({ hasText: prompt }).locator('.agent-terminal-output > div > .md'))
      .toContainText('There is one TODO worth doing here', { timeout: 20_000 });
    await expect(page.locator('#model-trigger')).toBeEnabled({ timeout: 30_000 });
    await expect(page.locator('#thread_draft-runtime')).toHaveCount(0);
    await expect(composer).toHaveValue('');
    await accessible();
  }
});
