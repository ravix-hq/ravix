import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAgentSettings } from './settings.js';
import { draftChoice } from './draft-runtime.js';

// The chip is "<agent> · <model>", then the runtime's effort and Fast once a
// turn has reported them (RAV-52); this spec is about the model part. A turn
// in progress adds a second line saying why it can't change (RAV-87).
const modelOf = title => (title ?? '').split('\n')[0].split(' · ').slice(0, 2).join(' · ');
const chipModel = page => expect.poll(async () => modelOf(await page.locator('#model-trigger').getAttribute('title')));

test('an account default selects the model for a new thread and leaves the existing thread unchanged', async ({ page }) => {
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Personal thread default');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'New track', exact: true })).toHaveCount(0);
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  const tabs = page.getByRole('navigation', { name: 'Threads', exact: true });
  const original = await tabs.locator('[aria-selected="true"]').getAttribute('data-thread-id');
  const originalModel = modelOf(await page.locator('#model-trigger').getAttribute('title'));
  const trackURL = page.url();
  // The default model for new threads is Settings › Agents' disclosure (RAV-77).
  const panel = await openAgentSettings(page);
  await panel.locator('#agent-manage-toggle').click();
  const choice = page.locator('#thread-default-choice');
  await expect(choice).toBeVisible();
  const options = await choice.locator('option').evaluateAll(nodes => nodes.map(n => ({ value: n.value, label: n.textContent.trim() })));
  const selected = options.find(o => o.value.startsWith('claude|') && !originalModel.includes(o.label.split(' · ')[1]));
  expect(selected).toBeTruthy();
  await choice.selectOption(selected.value);
  await page.getByRole('button', { name: 'Save thread default', exact: true }).click();
  await expect(page.getByText('Thread default saved.', { exact: true })).toBeVisible();
  // Back to the track, through the browser's history as a person would.
  await page.goBack();
  await page.goBack();
  await expect(page).toHaveURL(trackURL);
  await tabs.getByRole('button', { name: 'Add thread', exact: true }).click();
  const draft = page.locator('#draft-runtime');
  await expect(draftChoice(page, 'model')).toHaveValue(selected.value.split('|')[1]);
  await expect(page.locator('#draft-runtime-menu label:has(input:checked)', { hasText: 'Your default' })).toHaveCount(1);
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await composer.fill('Start on my default');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(tabs.locator('[aria-selected="true"]')).not.toHaveAttribute('data-thread-id', original);
  await expect(tabs.locator('[aria-selected="true"]')).not.toHaveAttribute('data-thread-id', 'draft');
  await chipModel(page).toBe(selected.label);
  // The first message is a turn, and the menu waits for it to finish.
  await expect(page.locator('#transcript-turns')).toContainText('Start on my default');
  await expect(page.locator('#model-trigger')).toBeEnabled({ timeout: 30_000 });
  await page.locator('#model-trigger').click();
  await expect(page.locator('.model-default-hint')).toHaveText('Also your default for new threads');
  await page.locator('#model-menu [phx-value-model=""]').click();
  await chipModel(page).toBe(originalModel);
  await tabs.getByRole('button', { name: 'Add thread', exact: true }).click();
  await expect(draftChoice(page, 'model')).not.toHaveValue(selected.value.split('|')[1]);
  await tabs.getByRole('button', { name: 'Discard new thread', exact: true }).click();
  await expect(draft).toHaveCount(0);
  await tabs.locator(`button[data-thread-id="${original}"]`).click();
  await chipModel(page).toBe(originalModel);
});
