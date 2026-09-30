import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-51 in a real browser: the path bar drives a cross-origin preview frame
// through the gateway's bridge without losing its session, a port with
// nothing on it is an empty state rather than a proxy error, and an answer
// that names a server offers it one click away. The provider mock runs real
// Vite servers behind the real Sprites tunnel protocol.
const devPort = Number(process.env.MOCK_DEV_PORT || 8895);

// A framed preview keeps its SameSite=Strict session only when the app and
// its preview hosts are one site, as they are in production. `localhost` and
// `*.preview.localhost` are not; `bun run test:browser:previews` runs this on
// `app.ravix.localhost`, beside `*.preview.ravix.localhost`, instead.
test.skip(!(process.env.BROWSER_HOST || '').endsWith('.localhost'), 'run with bun run test:browser:previews');

function previewFrame(page, port) {
  const host = port ? new RegExp(`--p${port}\\.preview\\.`) : /^http:\/\/t-[a-f0-9]+\.preview\./;
  return page.frames().find(frame => host.test(frame.url()));
}

async function framePath(page, port) {
  await expect.poll(() => previewFrame(page, port)?.url() ?? '').toMatch(/\.preview\./);
  return new URL(previewFrame(page, port).url()).pathname;
}

test('the path bar, the port picker and an agent-reported port', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: /^New project/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Preview ports');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled();
  await expect(page.locator('#transcript-status')).toHaveText('Agent replied');

  await page.locator('#yard .workspace-project.current button[title="Project settings"]').click();
  const settings = page.getByRole('dialog', { name: 'Project settings', exact: true });
  await settings.getByRole('button', { name: 'Run script', exact: true }).click();
  await settings.locator('#default-directory').fill('.');
  await settings.locator('#default-command').fill('npm run dev -- --port "$PORT" --strictPort');
  await settings.locator('#default-readiness').fill('/');
  await settings.getByRole('button', { name: 'Save defaults', exact: true }).click();
  await expect(page.getByText('Run script saved.', { exact: true })).toBeVisible();
  await settings.getByRole('button', { name: 'Close', exact: true }).click();

  // The run script, framed, with a path bar that navigates inside the gateway.
  await page.locator('button[phx-click="panel"][phx-value-name="preview"]').click();
  await page.locator('button[phx-value-action="run"]').click();
  await expect(page.locator('#run-status')).toHaveText('Status: ready');
  await page.locator('button[phx-value-action="open"]').click();
  const frame = page.frameLocator('#preview-frame');
  await expect(frame.getByRole('heading', { level: 1 })).toContainText('Live track');
  const location = page.locator('#preview-location');
  await expect(location).toHaveValue('/');

  await location.fill('docs/page?tab=2');
  await location.press('Enter');
  await expect.poll(() => framePath(page)).toBe('/docs/page');
  await expect(location).toHaveValue('/docs/page?tab=2');
  // Still the app, not a sign-in refusal: the session came along.
  await expect(frame.getByRole('heading', { level: 1 })).toContainText('Live track');

  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await expect.poll(() => framePath(page)).toBe('/');
  await expect(location).toHaveValue('/');
  await page.getByRole('button', { name: 'Forward', exact: true }).click();
  await expect.poll(() => framePath(page)).toBe('/docs/page');
  await page.getByRole('button', { name: 'Reload', exact: true }).click();
  await expect(frame.getByRole('heading', { level: 1 })).toContainText('Live track');

  // Nothing on the dev port yet: it is not offered, and asking for it
  // anyway is the empty state, not a proxy error.
  await expect(page.locator(`#preview-port option[value="${devPort}"]`)).toHaveCount(0);
  await page.evaluate(port => {
    const select = document.querySelector('#preview-port');
    select.add(new Option(`:${port}`, String(port)));
    select.value = String(port);
    select.dispatchEvent(new Event('change', { bubbles: true }));
  }, devPort);
  const empty = page.locator('#preview-unreachable');
  await expect(empty.getByRole('heading')).toHaveText(`Nothing is listening on :${devPort} yet`);
  await expect(empty.getByRole('button', { name: 'Retry', exact: true })).toBeVisible();
  await expect(empty.getByRole('button', { name: 'Run', exact: true })).toBeVisible();
  await expect(page.locator('#preview-frame')).toHaveCount(0);
  const result = await new AxeBuilder({ page }).include('#preview-view').withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);

  // The agent starts its own server and says where: one click to it.
  await composer.fill('Start the dev server');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  const offer = page.locator('#preview-offers').getByRole('button', { name: `Preview :${devPort}`, exact: true });
  await expect(offer).toBeVisible({ timeout: 30_000 });
  await offer.click();
  await expect(frame.getByRole('heading', { level: 1 })).toHaveText(`Agent's dev server · :${devPort}`);
  await expect(page.locator(`#preview-port option[value="${devPort}"]`)).toHaveJSProperty('selected', true);
  await frame.getByRole('link', { name: 'Docs', exact: true }).click();
  await expect(location).toHaveValue('/docs/');
  await page.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(location).toHaveValue('/');

  // And back to the run script from the picker.
  await page.locator('#preview-port').selectOption('');
  await expect(frame.getByRole('heading', { level: 1 })).toContainText('Live track');
  await page.locator('button[phx-value-action="stop"]').click();
  await expect(page.locator('#run-status')).toHaveText('Status: stopped');
});
