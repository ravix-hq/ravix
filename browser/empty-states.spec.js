import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

// The sandbox the mock made for this track: its vault is tagged with the track.
async function sandboxOf(request, trackId) {
  const vaults = (await (await request.get(`${mock}/api/vaults`)).json()).data;
  const vault = vaults.find(v => v.metadata?.ravix?.track === trackId);
  const boxes = (await (await request.get(`${mock}/api/sandboxes`)).json()).data;
  return boxes.find(b => b.vault_id === vault.id).id;
}

test('an asleep track says so once, in the inspector, and Wake wakes it', async ({ page, request }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'threadruntime', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.getByLabel('Project name', { exact: true }).fill('Empty states');
  await dialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(dialog).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/') && !url.search);
  await expect(page.locator('#track-machine-scope')).toHaveText('Own machine');

  // Setting up: the inspector says the banner's step, and turns while it does.
  const setup = page.locator('#panel-setup');
  await expect(setup).toBeVisible();
  await expect(setup.locator('h3')).toHaveText((await page.locator('#track-setup-status strong').textContent()).trim());
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  await expect(setup).toHaveCount(0);

  const trackId = new URL(page.url()).pathname.split('/t/')[1];
  const sandbox = await sandboxOf(request, trackId);
  expect((await request.post(`${mock}/__browser/sandbox-status`, { data: { id: sandbox, status: 'suspended' } })).ok()).toBe(true);
  await page.getByRole('button', { name: 'Refresh', exact: true }).click();

  const asleep = page.locator('#panel-asleep');
  await expect(asleep.getByRole('status')).toHaveText('Machine is asleep');
  // Centred in the pane, both ways.
  const [pane, box] = await Promise.all([
    page.locator('.workspace-panel').boundingBox(),
    asleep.locator('h3').boundingBox(),
  ]);
  expect(Math.abs((box.x + box.width / 2) - (pane.x + pane.width / 2))).toBeLessThan(4);
  expect(Math.abs((box.y + box.height / 2) - (pane.y + pane.height / 2))).toBeLessThan(40);
  // The header chip names the state; the dock is only its tab strip.
  await expect(page.locator('#track-machine-state')).toHaveText('Asleep');
  await expect(page.locator('#track-machine-status')).toHaveCount(0);
  // Only the header chip's description, for a screen reader, carries the rest.
  await expect(page.getByText('Your next message wakes it')).toHaveCount(1);
  await expect(page.locator('#track-machine-detail')).toHaveText('Your next message wakes it.');
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

  await page.getByRole('button', { name: 'Changes', exact: true }).click();
  await expect(asleep.getByRole('status')).toHaveText('Machine is asleep');

  expect((await request.post(`${mock}/__browser/clean-worktree`, { data: { id: sandbox } })).ok()).toBe(true);
  await asleep.getByRole('button', { name: 'Wake', exact: true }).click();
  await expect(asleep).toHaveCount(0, { timeout: 20_000 });
  await expect(page.locator('#changes-empty h3')).toHaveText('No changes yet');
  await expect(page.locator('#track-machine-state')).not.toHaveText('Asleep');

  await page.getByRole('button', { name: 'Preview', exact: true }).click();
  await expect(page.locator('#preview-empty h3')).toHaveText('No preview running');
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});
