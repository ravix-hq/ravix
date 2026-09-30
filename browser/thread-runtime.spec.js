import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';
import { connectApiKey } from './settings.js';
import { chooseDraft, draftChoice, draftModels, draftPill } from './draft-runtime.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

test('cohort threads attach the other runtime to the home disk and reuse its project agent', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'threadruntime');
  await connectApiKey(page, 'Claude Code', 'mock-thread-runtime-key');
  const list = async path => {
    const response = await request.get(`${mock}/api/${path}`);
    expect(response.ok()).toBe(true);
    return (await response.json()).data;
  };
  for (const [home, guest] of [['claude', 'codex'], ['codex', 'claude']]) {
    await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
    const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
    await project.getByLabel('Project name', { exact: true }).fill(`${home} home with ${guest} threads`);
    await project.locator(`#project-agent-${home}`).click();
    await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
    await expect(project).toHaveCount(0);
    const projectId = new URL(page.url()).pathname.split('/')[2];
    await page.locator('#yard .workspace-project.current .project-add').click();
    const track = page.getByRole('dialog', { name: 'New track', exact: true });
    await expect(track.locator('#new-track-model-menu input[name="new_track[runtime]"]:checked')).toHaveValue(home);
    await expect(track.locator('#new-track-model-trigger')).toContainText(home === 'codex' ? 'Codex · ' : 'Claude Code · ');
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
      const form = page.locator('#draft-runtime');
      const draftTab = page.locator('#thread-tab-draft');
      // All-dedicated projects use the saved project default for each new thread.
      await expect(draftChoice(page, 'runtime')).toHaveValue(home);
      if (home === 'claude' && n === 1) {
        const connections = page.locator('.thread-connections');
        await draftPill(page).click();
        await page.locator('#draft-runtime-menu').getByRole('button', { name: 'Connect Codex…', exact: true }).click();
        await connections.getByRole('button', { name: 'API key', exact: true }).click();
        await connections.getByLabel('API key', { exact: true }).fill('mock-inline-thread-key');
        await connections.getByRole('button', { name: 'Connect Codex', exact: true }).click();
        await expect(draftChoice(page, 'runtime')).toHaveValue('codex');
        await expect(draftTab).toContainText('Codex');
      }
      await chooseDraft(page, 'runtime', guest);
      // Model options arrive with the server's runtime patch, after the pick.
      await expect(draftTab).toContainText(guest === 'codex' ? 'Codex · ' : 'Claude Code · ');
      const model = (await draftModels(page)).at(-1);
      await chooseDraft(page, 'model', model);
      await page.getByRole('textbox', { name: 'Message', exact: true }).fill(`Guest thread ${n}`);
      await page.getByRole('button', { name: 'Send', exact: true }).click();
      await expect(form).toHaveCount(0);
      await expect(draftTab).toHaveCount(0);
      await expect(page.locator('.composer-model')).toContainText(guest === 'codex' ? 'Codex · ' : 'Claude Code · ');
      await expect(page.locator('.thread-tab[aria-selected=true] .thread-tab-agent')).toContainText(guest === 'codex' ? 'Codex · ' : 'Claude Code · ');
      await expect(page.locator('.thread-tab[aria-selected=true] .thread-tab-title')).toHaveText(`Guest Thread ${n}`);
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
          if (status === 'idle') await expect(page.locator('#thread-picker option').first()).not.toContainText('Idle');
          else await expect(page.locator('#thread-picker option').first()).toContainText(label);
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
