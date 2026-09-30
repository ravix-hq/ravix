import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

test('tool calls stream in as one labelled line each, with the thoughts in one toggle', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Tool rows');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
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
    data: { prompt: 'Demonstrate a tool-heavy turn' },
  });
  expect(submitted.ok()).toBe(true);

  // While the turn runs, the fold can be opened and each call arrives as a row.
  const turn = page.locator('.workspace-turn').filter({ hasText: 'Demonstrate a tool-heavy turn' });
  const summary = turn.locator('.workspace-work > summary');
  await expect(summary).toContainText('tool call', { timeout: 30_000 });
  await summary.click();
  const rows = turn.locator('.workspace-tool > summary');
  await expect(rows.first()).toBeVisible();
  const early = await rows.count();
  await expect.poll(() => rows.count(), { timeout: 15_000 }).toBeGreaterThan(early);
  // The fold stays open as rows are patched in.
  await expect(turn.locator('.workspace-work')).toHaveAttribute('open', '');

  await expect(turn.locator('.turn-footer time')).toBeVisible({ timeout: 30_000 });
  await expect(rows).toHaveCount(6);
  await expect(turn.locator('.workspace-work > summary')).toContainText('6 tool calls');
  await expect(turn.locator('.workspace-work > summary')).not.toContainText('thought');

  // The line shows the kinds of work done, first used first, as icons with
  // the words for a screen reader.
  const kinds = turn.locator('.workspace-work > summary .work-kinds > svg');
  expect(await kinds.evaluateAll(els => els.map(el => el.dataset.kind))).toEqual(['shell', 'read', 'edit']);
  await expect(turn.locator('.work-kinds .sr-only')).toHaveText('Used: shell, read, edit');

  // No native disclosure triangle: each toggle draws the app's chevron,
  // turned a quarter while open, and the row takes a hover background.
  const markers = await turn.locator('summary').evaluateAll(els => els.map(el => getComputedStyle(el).display));
  expect(markers).not.toContain('list-item');
  const turned = el => getComputedStyle(el).transform;
  const chevron = turn.locator('.workspace-work > summary > .disclosure-chevron');
  await expect.poll(() => chevron.evaluate(turned)).toMatch(/^matrix\(0, 1, -1, 0/);
  const background = () => summary.evaluate(el => getComputedStyle(el).backgroundColor);
  await page.mouse.move(0, 0);
  const resting = await background();
  await summary.hover();
  await expect.poll(background).not.toBe(resting);

  // Every row is one line however long its command, and names its tool.
  const heights = await rows.evaluateAll(els => els.map(el => el.getBoundingClientRect().height));
  expect(Math.max(...heights)).toBeLessThan(30);
  await expect(turn.locator('.workspace-tool .tool-name')).toHaveText(['Bash', 'Read', 'Bash', 'Edit', 'Bash', 'Bash']);
  const long = turn.locator('.workspace-tool .tool-target').nth(4);
  expect(await long.evaluate(el => getComputedStyle(el).textOverflow)).toBe('ellipsis');

  // The heredoc is one line in the row and its real lines when opened.
  const heredoc = rows.nth(2);
  await expect(heredoc).toHaveAttribute('title', "python3 - <<'PY'");
  await expect(heredoc.locator('.tool-more')).toHaveText('+7 lines');
  await heredoc.click();
  const command = turn.locator('.workspace-tool').nth(2).locator('pre.tool-command');
  expect((await command.textContent()).split('\n')).toHaveLength(8);

  // Five thoughts, one toggle, not a row between every call.
  await expect(turn.locator('.workspace-thinking')).toHaveCount(1);
  await expect(turn.locator('.workspace-thinking > summary')).toHaveText('5 thoughts');
  const thoughts = turn.locator('.workspace-thinking > summary > .disclosure-chevron');
  expect(await thoughts.evaluate(turned)).toBe('none');
  await turn.locator('.workspace-thinking > summary').click();
  await expect.poll(() => thoughts.evaluate(turned)).toMatch(/^matrix\(0, 1, -1, 0/);
});
