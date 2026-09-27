import { test, expect } from '@playwright/test';
import { signIn } from './sign-in.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test('cohort threads attach the other runtime to the home disk and reuse its project agent', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'threadruntime');
  for (const agent of ['Claude Code', 'Codex']) {
    await page.locator('#account-trigger').click();
    await page.locator('#open-account').click();
    const account = page.getByRole('dialog', { name: 'Your account', exact: true });
    await account.getByRole('button', { name: new RegExp(`^${agent}`) }).click();
    await account.getByRole('button', { name: 'API key', exact: true }).click();
    await account.getByLabel('API key', { exact: true }).fill('mock-thread-runtime-key');
    await account.getByRole('button', { name: `Connect ${agent}`, exact: true }).click();
    await expect(account.locator(`#held-${agent === 'Codex' ? 'codex' : 'claude'}-api_key`)).toBeVisible();
    await account.getByRole('button', { name: 'Close', exact: true }).click();
  }
  const list = async path => {
    const response = await request.get(`${mock}/api/${path}`);
    expect(response.ok()).toBe(true);
    return (await response.json()).data;
  };
  for (const [home, guest] of [['claude', 'codex'], ['codex', 'claude']]) {
    await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
    const project = page.getByRole('dialog', { name: 'New project', exact: true });
    await project.getByLabel('Project name', { exact: true }).fill(`${home} home with ${guest} threads`);
    await project.locator(`#project-agent-${home}`).click();
    await project.getByRole('button', { name: 'Create project', exact: true }).click();
    await expect(project).toHaveCount(0);
    const projectId = new URL(page.url()).pathname.split('/')[2];
    await page.getByRole('navigation', { name: 'Project tracks', exact: true })
      .getByRole('button', { name: 'New track', exact: true }).click();
    const track = page.getByRole('dialog', { name: 'New track', exact: true });
    await expect(track.getByLabel('Runtime', { exact: true })).toHaveValue(home);
    await track.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
    const homeAgent = (await list('agents')).find(a => a.metadata?.ravix?.project === projectId);
    expect(homeAgent.runtime).toBe(home);
    const homeConversation = (await list('conversations')).find(c => c.agent_id === homeAgent.id);
    expect(homeConversation.sandbox_id).toBeTruthy();
    let guestAgentId;
    for (let n = 1; n <= 2; n++) {
      await page.getByRole('button', { name: 'Add thread', exact: true }).click();
      const form = page.locator('#new-thread-form');
      await expect(form.getByLabel('Runtime', { exact: true })).toHaveValue(n === 1 ? home : guest);
      await form.getByLabel('Runtime', { exact: true }).selectOption(guest);
      const models = form.getByLabel('Model', { exact: true });
      const model = await models.locator('option').last().getAttribute('value');
      await models.selectOption(model);
      await form.getByRole('button', { name: 'Create thread', exact: true }).click();
      await expect(form).toHaveCount(0);
      const agents = (await list('agents')).filter(a => a.metadata?.ravix?.project === projectId);
      expect(agents.filter(a => a.runtime === guest)).toHaveLength(1);
      const guestAgent = agents.find(a => a.runtime === guest);
      if (guestAgentId) expect(guestAgent.id).toBe(guestAgentId);
      guestAgentId = guestAgent.id;
      const conversations = (await list('conversations')).filter(c => c.agent_id === guestAgentId);
      expect(conversations).toHaveLength(n);
      for (const conversation of conversations) {
        expect(conversation).toMatchObject({ sandbox_id: homeConversation.sandbox_id,
          environment_id: homeConversation.environment_id, vault_id: homeConversation.vault_id,
          runtime: guest, model });
      }
    }
  }
});
