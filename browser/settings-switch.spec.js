import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openProjectSettings, connectApiKey } from './settings.js';
import { openAddRepository } from './new-track.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test('the provider mock rejects attaching a changed runtime to the old machine in both directions', async ({ request }) => {
  for (const [from, to] of [['claude', 'codex'], ['codex', 'claude']]) {
    const response = await request.post(`${mock}/api/agents`, { data: { runtime: from } });
    const { data: agent } = await response.json();
    try {
      const opened = await request.post(`${mock}/api/conversations`, { data: { agent_id: agent.id, prompt: "Initialize the disposable runtime-switch fixture." } });
      expect(opened.ok()).toBe(true);
      const { data: conversation } = await opened.json();
      await request.put(`${mock}/api/agents/${agent.id}`, { data: { runtime: to } });
      const attached = await request.post(`${mock}/api/conversations`, {
        data: { agent_id: agent.id, sandbox_id: conversation.sandbox_id },
      });
      expect(attached.status()).toBe(422);
      expect(await attached.json()).toMatchObject({ error: 'sandbox_runtime_mismatch' });
    } finally {
      await request.delete(`${mock}/api/agents/${agent.id}`);
    }
  }
});

test('settings explicitly rebuilds when switching agents and the next track works', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  // Connect through the real account form; mock values never leave this fixture.
  for (const agent of ['Claude Code', 'Codex']) await connectApiKey(page, agent, 'mock-settings-switch-key');
  await openAddRepository(page);
  const create = page.getByRole('dialog', { name: 'Add a repository' });
  await create.getByLabel('Project name', { exact: true }).fill('Agent switch browser');
  await create.locator('#project-agent-claude').click();
  await create.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(create).not.toBeVisible();
  const projectUrl = page.url();
  const projectId = new URL(projectUrl).pathname.split('/')[2];
  let previousAgent;
  for (const target of ['codex', 'claude']) {
    await page.goto(projectUrl);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await page.locator('#top-new-track').click();
    await page.getByRole('dialog', { name: 'New track', exact: true })
      .getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
    const agents = (await (await request.get(`${mock}/api/agents`)).json()).data;
    const agent = agents.find(a => a.metadata?.ravix?.project === projectId);
    expect(agent.runtime).toBe(target === 'codex' ? 'claude' : 'codex');
    if (previousAgent) expect(agent.id).not.toBe(previousAgent);
    previousAgent = agent.id;
    // #243 named the track header's gear for what it opens.
    const settings = await openProjectSettings(page, 'agent');
    await expect(settings.locator('[data-confirm]')).toHaveCount(0);
    await settings.locator(`#settings-agent-${target}`).click();
    // RAV-74: one Save a page, in the bar, and here it is the switch.
    const bar = page.locator('#project-agent-bar');
    const save = bar.getByRole('button', { name: 'Switch & rebuild', exact: true });
    await expect(save).toBeVisible();
    // Leaving the section with the switch unsaved asks first (RAV-72).
    await settings.locator('#settings-nav-general').click();
    const leave = page.getByRole('alertdialog', { name: 'Leave without saving?' });
    await expect(leave).toBeVisible();
    await leave.getByRole('button', { name: 'Keep editing', exact: true }).click();
    await expect(leave).toBeHidden();
    await expect(page).toHaveURL(/\/settings\/agent$/);
    await save.click();
    const confirmation = settings.getByRole('group', { name: 'Confirm agent switch' });
    await expect(confirmation).toContainText("This closes 1 open track visible to you, plus any private tracks you cannot see, and discards the machine's disk");
    await expect(confirmation.getByRole('button', { name: 'Rebuild and switch' })).toBeFocused();
    await confirmation.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(confirmation).toHaveCount(0);
    await expect(settings.locator(`#settings-agent-${target}`)).toHaveAttribute('aria-pressed', 'true');
    await expect(save).toBeFocused();
    await save.click();
    await confirmation.getByRole('button', { name: 'Rebuild and switch' }).click();
    await expect(page).toHaveURL(/\/(home)?$/);
  }
  await page.goto(projectUrl);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await page.locator('#top-new-track').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
});


test('settings connects an unavailable agent inline, retains the draft, and can discard before leaving', async ({ page }) => {
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  const create = page.getByRole('dialog', { name: 'Add a repository' });
  await create.getByLabel('Project name', { exact: true }).fill('Inline settings connection');
  await create.locator('#project-agent-claude').click();
  await create.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(create).not.toBeVisible();
  const settings = await openProjectSettings(page, 'agent');
  await settings.locator('#settings-agent-codex').click();
  await expect(settings.locator('#settings-agent-codex')).toContainText('Not connected');
  const bar = page.locator('#project-agent-bar');
  await expect(bar.getByRole('button', { name: 'Switch & rebuild', exact: true })).toBeVisible();
  await expect(settings.locator('#settings-connect-codex')).toBeVisible();
  await settings.getByLabel('Instructions', { exact: true }).fill('Keep my draft');
  await settings.getByRole('button', { name: 'API key', exact: true }).click();
  await settings.getByLabel('API key', { exact: true }).fill('sk-browser-settings-fixture');
  await settings.getByRole('button', { name: 'Connect Codex', exact: true }).click();
  await expect(settings.locator('#settings-agent-codex')).toContainText('Connected');
  await expect(settings.locator('#settings-agent-codex')).toHaveAttribute('aria-pressed', 'true');
  await expect(settings.getByLabel('Instructions', { exact: true })).toHaveValue('Keep my draft');
  await bar.getByRole('button', { name: 'Switch & rebuild', exact: true }).click();
  await expect(settings.locator('#agent-switch-confirmation')).toBeVisible();
  await settings.locator('#agent-switch-confirmation').getByRole('button', { name: 'Cancel', exact: true }).click();
  await bar.getByRole('button', { name: 'Discard', exact: true }).click();
  await expect(bar).toBeHidden();
  await expect(settings.locator('#settings-agent-claude')).toHaveAttribute('aria-pressed', 'true');
  await expect(bar.locator('[data-unsaved-save]')).toHaveText('Save');
  await expect(settings.getByLabel('Instructions', { exact: true })).toHaveValue('');
  // Discarded, nothing is left to ask about.
  await settings.locator('#settings-nav-general').click();
  await expect(page).toHaveURL(/\/settings\/general$/);
  await expect(page.getByRole('alertdialog', { name: 'Leave without saving?' })).toBeHidden();
});
