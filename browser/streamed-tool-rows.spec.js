import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-92: the Claude adapter opens a Write as "Preparing file…" and a Bash
// call as "Terminal", and names the path or command only in later updates.
test('streamed Write and Bash rows finish with their path and command, and output is not clipped', async ({ page, request }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1100, height: 900 });
  await signIn(page, 'dana');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Streamed rows');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectId = new URL(page.url()).pathname.split('/')[2];
  await page.locator('#top-new-track').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
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
    data: { prompt: 'Demonstrate a streamed write' },
  });
  expect(submitted.ok()).toBe(true);

  const turn = page.locator('.workspace-turn').filter({ hasText: 'Demonstrate a streamed write' });
  await expect(turn.locator('.turn-footer time')).toBeVisible({ timeout: 30_000 });
  await turn.locator('.workspace-work > summary').click();
  const tools = turn.locator('.workspace-tool');
  await expect(tools).toHaveCount(2);
  if (process.env.RAV92_SHOT) {
    await page.setViewportSize({ width: 1100, height: 1500 });
    await tools.nth(1).locator('summary').click();
    await turn.screenshot({ path: process.env.RAV92_SHOT });
    await page.setViewportSize({ width: 1100, height: 900 });
    await tools.nth(1).locator('summary').click();
  }

  // The rows name the file and the command, relative to the track, and no
  // placeholder or sandbox path is left on them.
  await expect(tools.locator('.tool-name')).toHaveText(['Write', 'Bash']);
  await expect(tools.locator('.tool-target')).toHaveText([
    'src/lib/day.ts',
    'bun test src/lib/day.test.ts --reporter=verbose',
  ]);
  await expect(turn.locator('.workspace-work')).not.toContainText('Preparing file');
  await expect(turn.locator('.workspace-work')).not.toContainText('Terminal');
  await expect(turn.locator('.workspace-tool > summary')).not.toContainText(['/home/sprite/work']);

  // Opened, the Write shows its content and the Bash its output, and every
  // line of it is inside the transcript: wrapped, or scrolled within its box.
  await tools.nth(0).locator('summary').click();
  await expect(tools.nth(0).locator('.tool-body')).toContainText('export const localDay');
  await expect(tools.nth(0).locator('pre.tool-output')).toHaveText(/^File created successfully at: src\/lib\/day\.ts /);
  await expect(tools.nth(0).locator('.tool-body')).not.toContainText('/home/sprite/work');
  if (process.env.RAV92_OPEN_SHOT) {
    await page.setViewportSize({ width: 1100, height: 1500 });
    await tools.nth(1).locator('summary').click();
    await turn.screenshot({ path: process.env.RAV92_OPEN_SHOT });
    await tools.nth(1).locator('summary').click();
    await page.setViewportSize({ width: 1100, height: 900 });
  }
  await tools.nth(0).locator('summary').click();
  await tools.nth(1).locator('summary').click();
  const output = tools.nth(1).locator('pre.tool-output');
  await expect(output).toContainText('spring-forward transition');
  await expect(tools.nth(1).locator('.tool-body')).not.toContainText('/home/sprite/work');
  const box = await output.boundingBox();
  const column = await turn.boundingBox();
  expect(box.x + box.width).toBeLessThanOrEqual(column.x + column.width + 1);
  expect(await output.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  // Long output scrolls inside its box rather than being cut at its height.
  expect(await output.evaluate(el => getComputedStyle(el).overflowY)).toBe('auto');
  await output.evaluate(el => { el.scrollTop = el.scrollHeight; });
  await expect.poll(() => output.evaluate(el => el.scrollTop > 0)).toBe(true);
});
