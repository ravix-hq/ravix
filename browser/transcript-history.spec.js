import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('newest turns render first and loading earlier preserves the visible turn', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Transcript history');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectId = new URL(page.url()).pathname.split('/')[2];
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  await expect(page.getByRole('button', { name: 'Add thread', exact: true })).toBeEnabled({ timeout: 60_000 });
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;
  const list = async path => (await (await request.get(`${mock}/api/${path}`)).json()).data;
  const agent = (await list('agents')).find(agent => agent.metadata?.ravix?.project === projectId);
  const conversation = (await list('conversations')).find(c => c.agent_id === agent.id);
  // Disconnect before seeding: the test exercises initial loading, not 7,000 SSE updates.
  const url = page.url();
  await page.goto('/healthz');
  const seeded = await request.post(`${mock}/__browser/long-transcript`, { data: { id: conversation.id } });
  expect(seeded.ok()).toBe(true);
  await page.goto(url);
  const turns = page.locator('#transcript-turns > article');
  // One newest-first page: 200 events of 20-event turns is the newest ten, whole.
  await expect(turns).toHaveCount(10);
  await expect(turns.first()).toContainText('History prompt 341');
  await expect(turns.last()).toContainText('History prompt 350');
  await expect(page.getByText('History answer 350: line 17.', { exact: true })).toBeInViewport();
  const scroller = page.locator('#transcript-scroll');
  await scroller.evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')); });
  await expect(page.locator('#load-earlier')).toBeInViewport();
  const anchor = turns.first();
  const id = await anchor.getAttribute('id');
  const before = await anchor.evaluate(el => el.getBoundingClientRect().top);
  await page.locator('#load-earlier').click();
  await expect(turns).toHaveCount(20);
  await expect(turns.first()).toContainText('History prompt 331');
  await expect(turns.last()).toContainText('History prompt 350');
  await expect.poll(async () => Math.abs(await page.locator(`[id="${id}"]`).evaluate(el => el.getBoundingClientRect().top) - before)).toBeLessThan(3);
  expect(new Set(await turns.evaluateAll(nodes => nodes.map(n => n.id))).size).toBe(20);
});
