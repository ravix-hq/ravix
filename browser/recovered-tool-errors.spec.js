import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('recovered tool errors are muted while expanded errors retain their status', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Recovered errors');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectId = new URL(page.url()).pathname.split("/")[2];
  await page.getByRole('navigation', { name: 'Project tracks', exact: true })
    .getByRole('button', { name: 'New track', exact: true }).click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await expect(page.getByRole('button', { name: 'Add thread', exact: true }))
    .toBeEnabled({ timeout: 60_000 });
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;
  const list = async path => {
    const response = await request.get(`${mock}/api/${path}`);
    expect(response.ok()).toBe(true);
    return (await response.json()).data;
  };
  const agent = (await list('agents')).find(agent => agent.metadata?.ravix?.project === projectId);
  const conversation = (await list('conversations')).find(conversation => conversation.agent_id === agent.id);
  // Seed the transcript at the provider boundary; prompt delivery has its own browser coverage.
  const submitted = await request.post(`${mock}/api/conversations/${conversation.id}/prompts`, {
    data: { prompt: 'Demonstrate a recovered tool error' },
  });
  expect(submitted.ok()).toBe(true);
  await expect.poll(async () => {
    const turns = await list(`conversations/${conversation.id}/turns`);
    return turns.find(turn => turn.prompt.endsWith('Demonstrate a recovered tool error'))?.status;
  }, { timeout: 30_000 }).toBe('completed');
  // Inspect the persisted completed transcript, independently of stream-refresh timing.
  await page.reload();
  const turn = page.locator('.workspace-turn').filter({ hasText: 'The fix is complete.' });
  const summary = turn.locator('.workspace-work > summary');
  const recovered = summary.locator('.tool-recovered');
  await expect(recovered).toHaveText('1 recovered tool error', { timeout: 30_000 });
  await expect(summary.locator('.tool-error')).toHaveCount(0);
  expect(await recovered.evaluate(el => getComputedStyle(el).color))
    .toBe(await summary.evaluate(el => getComputedStyle(el).color));
  await summary.click();
  const failed = turn.locator('.workspace-tool').filter({ has: page.locator('.tool-error') });
  await expect(failed.locator('.tool-error')).toHaveText('error');
  expect(await failed.locator('.tool-error').evaluate(el => getComputedStyle(el).color))
    .not.toBe(await recovered.evaluate(el => getComputedStyle(el).color));
  await failed.locator('summary').click();
  await expect(failed).toContainText('1 test failed');
});
