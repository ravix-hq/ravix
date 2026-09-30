import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

// The sandbox the mock made for this track: its vault is tagged with the track.
async function sandboxOf(request, trackId) {
  const vaults = (await (await request.get(`${mock}/api/vaults`)).json()).data;
  const vault = vaults.find(v => v.metadata?.ravix?.track === trackId);
  const boxes = (await (await request.get(`${mock}/api/sandboxes`)).json()).data;
  return boxes.find(b => b.vault_id === vault.id).id;
}

async function newTrack(page, request, name) {
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'New project', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');
  // The machine exists once setup has run; the chip says Idle then.
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 45_000 });
  const trackId = new URL(page.url()).pathname.split('/t/')[1];
  return sandboxOf(request, trackId);
}

// RAV-81: + on a sleeping machine wakes it, as the inspector's Wake does,
// and then connects; it never waits out a handshake the machine cannot answer.
test('a terminal opened on a sleeping machine wakes it, then connects', async ({ page, request }) => {
  test.setTimeout(120_000);
  const sandbox = await newTrack(page, request, 'Terminal wake');
  expect((await request.post(`${mock}/__browser/sandbox-status`, { data: { id: sandbox, status: 'suspended', wake_ms: 1500 } })).ok()).toBe(true);
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();
  await expect(page.locator('#track-machine-state')).toHaveText('Asleep');

  await page.getByRole('button', { name: 'New terminal', exact: true }).click();
  const pane = page.locator('.shell-pane:not([hidden])');
  await expect(pane.getByRole('status')).toHaveText('Waking the machine…');
  await expect(pane.locator('.xterm-rows')).toContainText(/\S+ \$ /, { timeout: 20_000 });
  await expect(pane.locator('.empty')).toHaveCount(0);
  await expect(pane.locator('.shell-status')).toHaveCount(0);
  await expect(page.locator('#track-machine-state')).not.toHaveText('Asleep');

  await page.keyboard.type('pwd');
  await page.keyboard.press('Enter');
  await expect(pane.locator('.xterm-rows')).toContainText('/home/sprite/work/');
  await expect(page.locator('body')).not.toContainText('Sprites');
});

// A machine that does not answer the terminal at all: said in the app's
// words, with a Retry that works once the machine does.
test('a terminal the machine does not answer says so, and Retry connects', async ({ page, request }) => {
  test.setTimeout(120_000);
  const sandbox = await newTrack(page, request, 'Terminal retry');
  expect((await request.post(`${mock}/__browser/pty-silent`, { data: { id: sandbox, silent: true } })).ok()).toBe(true);

  await page.getByRole('button', { name: 'New terminal', exact: true }).click();
  const pane = page.locator('.shell-pane:not([hidden])');
  await expect(pane.locator('.shell-status')).toHaveText(/Connecting/);
  const status = pane.locator('.shell-status');
  await expect(status).toContainText("The machine didn't answer.", { timeout: 30_000 });
  await expect(page.locator('body')).not.toContainText('Sprites');
  await expect(status.getByRole('button', { name: 'Close tab' })).toHaveCount(0);

  expect((await request.post(`${mock}/__browser/pty-silent`, { data: { id: sandbox, silent: false } })).ok()).toBe(true);
  await status.getByRole('button', { name: 'Retry', exact: true }).click();
  await expect(pane.locator('.xterm-rows')).toContainText(/\S+ \$ /, { timeout: 20_000 });
  await expect(pane.locator('.shell-status')).toHaveCount(0);
  await expect(page.locator('[data-shell-tab]')).toHaveCount(1);
});
