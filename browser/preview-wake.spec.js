import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

// The sandbox the mock made for this track: its vault is tagged with the track.
async function sandboxOf(request, trackId) {
  const vaults = (await (await request.get(`${mock}/api/vaults`)).json()).data;
  const vault = vaults.find(v => v.metadata?.ravix?.track === trackId);
  const boxes = (await (await request.get(`${mock}/api/sandboxes`)).json()).data;
  return boxes.find(b => b.vault_id === vault.id).id;
}

// Every distinct thing the header chip and the preview status say, in order,
// as the page draws them. The page records its own transitions: a state can
// come and go between two polls of the test.
function recordStates() {
  window.__seen = [];
  const read = () => {
    const chip = document.getElementById('track-machine-state')?.textContent.trim() || '';
    const status = document.getElementById('run-status')?.textContent.trim() || '';
    const now = `${chip} | ${status}`;
    const seen = window.__seen;
    if (seen[seen.length - 1] !== now) seen.push(now);
  };
  new MutationObserver(read).observe(document, { subtree: true, childList: true, characterData: true });
}

test('RAV-40: a preview on an asleep machine wakes it, says so throughout, and a failure says why', async ({ page, request }) => {
  test.setTimeout(180_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.addInitScript(recordStates);
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Preview wake');
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#top-new-track').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });

  const chip = page.locator('#track-machine-state');
  const status = page.locator('#run-status');
  const empty = page.locator('#preview-empty');
  const run = empty.getByRole('button', { name: 'Run', exact: true });

  // With no run script, a start fails, says why, and offers Retry and Logs
  // in the pane's centre. Nothing spins.
  await page.locator('#track-tab-preview').click();
  await expect(empty.locator('h3')).toHaveText('No preview running');
  await run.click();
  const failed = page.locator('#preview-failed');
  await expect(failed.getByRole('alert')).toContainText('No run script configured');
  await expect(failed.getByRole('button', { name: 'Retry', exact: true })).toBeEnabled();
  await expect(failed.getByRole('button', { name: 'Logs', exact: true })).toBeVisible();
  await expect(page.locator('#preview-loading')).toHaveCount(0);
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await page.screenshot({ path: 'tmp/rav-40-4-failed.png' });

  // A run script, as the track's own override.
  await page.locator('#preview-config summary').click();
  await page.locator('#preview-directory').fill('.');
  await page.locator('#preview-command').fill('npm run dev -- --port "$PORT" --strictPort');
  await page.locator('#preview-path').fill('/');
  await page.locator('#preview-config-form').getByRole('button', { name: 'Save', exact: true }).click();
  await expect(empty.locator('h3')).toHaveText('No preview running');

  // The machine goes to sleep, and takes a few seconds to wake. A refused
  // read is how the page learns it is asleep, as it would from Fountain.
  const trackId = new URL(page.url()).pathname.split('/t/')[1];
  const sandbox = await sandboxOf(request, trackId);
  expect((await request.post(`${mock}/__browser/sandbox-status`, { data: { id: sandbox, status: 'suspended', wake_ms: 4000 } })).ok()).toBe(true);
  await page.locator('#track-tab-files').click();
  await page.locator('.panel-refresh').click();
  await expect(chip).toHaveText('Asleep');
  await page.locator('#track-tab-preview').click();
  await expect(empty.locator('h3')).toHaveText('No preview running');
  await page.evaluate(() => { window.__seen = []; });

  // The click answers at once, and the machine is waking: the header, the
  // dock and the panel all say so.
  await run.click();
  await page.screenshot({ path: 'tmp/rav-40-1-click.png' });
  await expect(status).toHaveText('Status: waking');
  await expect(page.locator('#preview-loading')).toContainText("Waking this track's machine");
  await expect(chip).toHaveText('Starting');
  await expect(page.locator('#track-machine-detail')).toHaveText("Waking this track's machine for the preview…");
  await page.screenshot({ path: 'tmp/rav-40-2-waking.png' });
  await expect(status).toHaveText('Status: starting', { timeout: 20_000 });
  await expect(chip).not.toHaveText('Asleep');
  await page.screenshot({ path: 'tmp/rav-40-2b-starting.png' });

  await expect(status).toHaveText('Status: ready', { timeout: 60_000 });
  await expect(chip).not.toHaveText('Asleep');

  // Waking, then starting, then ready, in that order, each arriving without
  // a click; and while the panel was busy the header never said Asleep.
  const seen = await page.evaluate(() => window.__seen);
  const statuses = seen.map(s => s.split(' | ')[1]).filter((s, i, all) => s && s !== all[i - 1]);
  expect(statuses.filter(s => ['Status: waking', 'Status: starting', 'Status: ready'].includes(s)))
    .toEqual(['Status: waking', 'Status: starting', 'Status: ready']);
  expect(seen.filter(s => /Status: (waking|starting)/.test(s) && s.startsWith('Asleep'))).toEqual([]);

  // Opened with a ticket minted for this session. What the gateway then
  // serves inside it is the gateway's own suite's to prove.
  await page.locator('button[phx-value-action="open"]').click();
  await expect(status).toHaveText('Status: ready', { timeout: 60_000 });
  await expect(page.locator('iframe.workspace-preview')).toHaveAttribute('src', /\/__ravix\/open#.+/);
  await page.screenshot({ path: 'tmp/rav-40-3-ready.png' });

  // Leave nothing running for the specs after this one: a preview with a
  // live lease is kept up by the reconciler for as long as it lasts.
  await page.locator('button[phx-value-action="stop"]').click();
  await expect(empty.locator('h3')).toHaveText('No preview running');
});
