import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test('cohort threads attach the other runtime to the home disk and reuse its project agent', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'threadruntime');
  for (const agent of ['Claude Code']) {
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
    await page.locator('#yard .workspace-project.current .project-add').click();
    const track = page.getByRole('dialog', { name: 'New track', exact: true });
    await expect(track.getByLabel('Agent', { exact: true })).toHaveValue(home);
    await track.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
    // Readiness is durable; the live-region announcement only describes new stream events.
    await expect(page.getByRole('button', { name: 'Add thread', exact: true })).toBeEnabled({ timeout: 30_000 });
    await expect(page.locator('#track-setup-status')).toHaveCount(0);
    const homeAgent = (await list('agents')).find(a => a.metadata?.ravix?.project === projectId);
    expect(homeAgent.runtime).toBe(home);
    const homeConversation = (await list('conversations')).find(c => c.agent_id === homeAgent.id);
    expect(homeConversation.sandbox_id).toBeTruthy();
    let guestAgentId;
    for (let n = 1; n <= 2; n++) {
      await page.getByRole('button', { name: 'Add thread', exact: true }).click();
      const form = page.locator('#new-thread-form');
      // All-dedicated projects use the saved project default for each new thread.
      await expect(form.getByLabel('Agent', { exact: true })).toHaveValue(home);
      if (home === 'claude' && n === 1) {
        const dialog = page.getByRole('dialog', { name: 'New thread', exact: true });
        await dialog.getByRole('button', { name: 'Connect to use Codex', exact: true }).click();
        await dialog.getByRole('button', { name: 'API key', exact: true }).click();
        await dialog.getByLabel('API key', { exact: true }).fill('mock-inline-thread-key');
        await dialog.getByRole('button', { name: 'Connect Codex', exact: true }).click();
        await expect(form.getByLabel('Agent', { exact: true })).toHaveValue('codex');
        await expect(dialog).toContainText('You are creating a Codex thread.');
      }
      await form.getByLabel('Agent', { exact: true }).selectOption(guest);
      // Model options arrive with the server's runtime patch, after selectOption returns.
      await expect(page.locator('#new-thread-dialog')).toContainText(
        `You are creating a ${guest === 'codex' ? 'Codex' : 'Claude Code'} thread.`);
      const models = form.getByLabel('Model', { exact: true });
      const model = await models.locator('option').last().getAttribute('value');
      await models.selectOption(model);
      await form.getByRole('button', { name: 'Create thread', exact: true }).click();
      await expect(form).toHaveCount(0);
      await expect(page.locator('.composer-model')).toContainText(guest === 'codex' ? 'Codex · ' : 'Claude Code · ');
      await expect(page.locator('.thread-tab[aria-current=true] .thread-tab-agent')).toContainText(guest === 'codex' ? 'Codex · ' : 'Claude Code · ');
      if (home === 'claude' && n === 1) {
        const homeTab = page.locator('.thread-tab').first();
        const notice = page.locator('#threads-working');
        const composer = page.getByRole('textbox', { name: 'Message', exact: true });
        await composer.fill('Draft stays available while another thread works');
        const changeState = async status => {
          const response = await request.post(`${mock}/__browser/conversation-state`, {
            data: { id: homeConversation.id, status, emit: true },
          });
          expect(response.ok()).toBe(true);
        };
        await changeState('running');
        await expect(homeTab).toHaveAccessibleName(/Running/);
        await expect(notice).toContainText('(Claude Code) is working in this checkout');
        for (const width of [1280, 500]) {
          await page.setViewportSize({ width, height: 900 });
          await expect(composer).toBeEnabled();
          await expect(composer).toHaveValue('Draft stays available while another thread works');
          const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
          expect(axe.violations).toEqual([]);
        }
        for (const [status, label] of [['pending', 'Queued'], ['failed', 'Failed'], ['idle', 'Idle']]) {
          await changeState(status);
          await expect(page.locator('#thread-picker option').first()).toContainText(label);
          await expect(notice).toHaveCount(0);
        }
        await page.setViewportSize({ width: 1280, height: 900 });
      }
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
