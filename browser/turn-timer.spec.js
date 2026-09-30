import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('a running turn shows its elapsed time ticking until the final duration replaces it', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Turn timer');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectId = new URL(page.url()).pathname.split("/")[2];
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
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
  const submitted = await request.post(`${mock}/api/conversations/${conversation.id}/prompts`, {
    data: { prompt: 'Demonstrate a long-running turn' },
  });
  expect(submitted.ok()).toBe(true);

  const turn = page.locator('.workspace-turn').filter({ hasText: 'Running the scheduler tests' });
  const elapsed = turn.locator('.turn-running .turn-elapsed');
  await expect(elapsed).toHaveText(/^\d+s$/, { timeout: 30_000 });
  const seconds = async () => Number((await elapsed.textContent()).replace('s', ''));
  const first = await seconds();
  await expect.poll(seconds, { timeout: 5_000 }).toBeGreaterThanOrEqual(first + 2);

  // A reload resumes from the turn's real start, not from zero.
  const before = await seconds();
  await page.reload();
  await expect(elapsed).toHaveText(/^\d+s$/, { timeout: 30_000 });
  expect(await seconds()).toBeGreaterThanOrEqual(before);

  // Settling swaps the ticking clock for the server's final duration.
  await expect(turn.locator('.turn-footer time')).toBeVisible({ timeout: 30_000 });
  await expect(elapsed).toHaveCount(0);
  const final = Number((await turn.locator('.turn-footer > span').first().textContent()).replace('s', ''));
  expect(final).toBeGreaterThanOrEqual(12);
  expect(final).toBeLessThan(60);
});
