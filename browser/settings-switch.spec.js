import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test('the provider mock rejects attaching a changed runtime to the old machine in both directions', async ({ request }) => {
  for (const [from, to] of [['claude', 'codex'], ['codex', 'claude']]) {
    const response = await request.post(`${mock}/api/agents`, { data: { runtime: from } });
    const { data: agent } = await response.json();
    try {
      const opened = await request.post(`${mock}/api/conversations`, { data: { agent_id: agent.id } });
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
  for (const agent of ['Claude Code', 'Codex']) {
    await page.locator('#account-trigger').click();
    await page.locator('#open-account').click();
    const account = page.getByRole('dialog', { name: 'Your account', exact: true });
    await account.getByRole('button', { name: new RegExp(`^${agent}`) }).click();
    await account.getByRole('button', { name: 'API key', exact: true }).click();
    await account.getByLabel('API key', { exact: true }).fill('mock-settings-switch-key');
    await account.getByRole('button', { name: `Connect ${agent}`, exact: true }).click();
    await expect(account.locator(`#held-${agent === 'Codex' ? 'codex' : 'claude'}-api_key`)).toBeVisible();
    await account.getByRole('button', { name: 'Close', exact: true }).click();
  }
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const create = page.getByRole('dialog', { name: 'New project' });
  await create.getByLabel('Project name', { exact: true }).fill('Agent switch browser');
  await create.locator('#project-agent-claude').click();
  await create.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(create).not.toBeVisible();
  const projectUrl = page.url();
  const projectId = new URL(projectUrl).pathname.split('/')[2];
  let previousAgent;
  for (const target of ['codex', 'claude']) {
    await page.goto(projectUrl);
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await page.getByRole('navigation', { name: 'Project tracks', exact: true })
      .getByRole('button', { name: 'New track', exact: true }).click();
    await page.getByRole('dialog', { name: 'New track', exact: true })
      .getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
    const agents = (await (await request.get(`${mock}/api/agents`)).json()).data;
    const agent = agents.find(a => a.metadata?.ravix?.project === projectId);
    expect(agent.runtime).toBe(target === 'codex' ? 'claude' : 'codex');
    if (previousAgent) expect(agent.id).not.toBe(previousAgent);
    previousAgent = agent.id;
    // #243 named the track header's gear for what it opens.
    await page.locator('.track-crumbs').getByRole('button', { name: 'Project settings', exact: true }).click();
    const settings = page.getByRole('dialog', { name: 'Project settings', exact: true });
    await expect(settings.locator('[data-confirm]')).toHaveCount(0);
    await settings.getByRole('button', { name: 'Agent', exact: true }).click();
    await settings.locator(`#settings-agent-${target}`).click();
    await expect(settings.getByRole('button', { name: 'Save agent', exact: true })).toBeHidden();
    await settings.getByRole('button', { name: 'General', exact: true }).click();
    await expect(settings.getByRole('button', { name: 'Switch and rebuild', exact: true })).toBeFocused();
    await settings.getByRole('button', { name: 'Switch and rebuild', exact: true }).click();
    const confirmation = settings.getByRole('group', { name: 'Confirm agent switch' });
    await expect(confirmation).toContainText("This closes 1 open track and discards the machine's disk");
    await expect(confirmation.getByRole('button', { name: 'Rebuild and switch' })).toBeFocused();
    await confirmation.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(confirmation).toHaveCount(0);
    await expect(settings.locator(`#settings-agent-${target}`)).toHaveAttribute('aria-pressed', 'true');
    await expect(settings.getByRole('button', { name: 'Switch and rebuild', exact: true })).toBeFocused();
    await settings.getByRole('button', { name: 'Switch and rebuild', exact: true }).click();
    await confirmation.getByRole('button', { name: 'Rebuild and switch' }).click();
    await expect(page).toHaveURL(/\/(home)?$/);
  }
  await page.goto(projectUrl);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await page.getByRole('navigation', { name: 'Project tracks', exact: true })
    .getByRole('button', { name: 'New track', exact: true }).click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
});


test('settings connects an unavailable agent inline, retains the draft, and can discard before closing', async ({ page }) => {
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: /^Quick start/ }).click();
  const create = page.getByRole('dialog', { name: 'New project' });
  await create.getByLabel('Project name', { exact: true }).fill('Inline settings connection');
  await create.locator('#project-agent-claude').click();
  await create.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(create).not.toBeVisible();
  await page.locator('.crumbs').getByRole('button', { name: 'Settings', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Project settings', exact: true });
  await settings.getByRole('button', { name: 'Agent', exact: true }).click();
  await settings.locator('#settings-agent-codex').click();
  await expect(settings.locator('#settings-agent-codex')).toContainText('Not connected');
  await expect(settings.getByRole('button', { name: 'Switch and rebuild', exact: true })).toBeDisabled();
  await settings.getByLabel('Instructions', { exact: true }).fill('Keep my draft');
  await settings.getByRole('button', { name: 'API key', exact: true }).click();
  await settings.getByLabel('API key', { exact: true }).fill('sk-browser-settings-fixture');
  await settings.getByRole('button', { name: 'Connect Codex', exact: true }).click();
  await expect(settings.locator('#settings-agent-codex')).toContainText('Connected');
  await expect(settings.locator('#settings-agent-codex')).toHaveAttribute('aria-pressed', 'true');
  await expect(settings.getByLabel('Instructions', { exact: true })).toHaveValue('Keep my draft');
  await settings.getByRole('button', { name: 'Switch and rebuild', exact: true }).click();
  await expect(settings.locator('#agent-switch-confirmation')).toBeVisible();
  await settings.getByRole('button', { name: 'Cancel', exact: true }).click();
  await settings.getByRole('button', { name: 'Discard changes', exact: true }).click();
  await expect(settings.locator('#settings-agent-claude')).toHaveAttribute('aria-pressed', 'true');
  await expect(settings.getByRole('button', { name: 'Save agent', exact: true })).toBeVisible();
  await settings.getByRole('button', { name: 'Close', exact: true }).click();
  await expect(settings).not.toBeVisible();
});
