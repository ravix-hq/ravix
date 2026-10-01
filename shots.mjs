// Screenshots of the agent-connection step for RAV-133/134/135, against the
// browser harness (`python3 browser/server.py`, prod build + provider mock).
//   bun tmp/shots/shots.mjs <outdir> <login>
import { chromium } from '@playwright/test';
import { mkdirSync } from 'node:fs';

const [outDir, login = 'connectstep'] = process.argv.slice(2);
const base = `http://localhost:${process.env.BROWSER_PORT || 4103}`;
const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 1180, height: 860 }, deviceScaleFactor: 2, baseURL: base });
const page = await context.newPage();
const shot = (name) => page.screenshot({ path: `${outDir}/${name}.png` });
const connected = async () => { await page.locator('[data-phx-main].phx-connected').waitFor(); };
const settle = () => page.evaluate(() => Promise.all(document.getAnimations()
  .filter(a => a.effect?.getTiming?.().iterations !== Infinity).map(a => a.finished.catch(() => {}))));

async function signIn() {
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
  await page.getByRole('link', { name: `Sign in as @${login}`, exact: true }).click();
  await page.getByRole('link', { name: 'Sign out' }).or(page.locator('#account-trigger')).first().waitFor();
  await connected();
  await page.locator('#project-sections[aria-busy="false"]').or(page.getByRole('button', { name: 'Skip setup', exact: true })).first().waitFor({ state: 'attached' });
  if (new URL(page.url()).pathname.startsWith('/welcome')) {
    await page.getByRole('button', { name: 'Skip setup', exact: true }).click();
    await page.waitForURL(/\/home$/);
  }
}

async function theme(name) {
  await page.evaluate((t) => localStorage.setItem('ravix.theme', t), name);
}

async function openDialog() {
  await page.goto('/home');
  await connected();
  await page.locator('#yard .yard-nav').getByRole('button', { name: 'Add a repository', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await dialog.locator('#project-agent-claude').click();
  await dialog.locator('#credential-form').waitFor();
  await dialog.locator('#project-repositories').waitFor();
  await settle();
  return dialog;
}

await signIn();

// (d) the same panel in the walkthrough and in Settings › Agents.
await page.goto('/welcome/agent');
await connected();
await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
await page.locator('#credential-form').waitFor();
await settle();
await shot('welcome-agent');

await page.goto('/settings/agents');
await connected();
await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
await page.locator('#credential-form').waitFor();
await settle();
await shot('settings-agents');

// (a) Add a repository, Claude not connected, a token pasted; both themes.
for (const [name, label] of [['ravix', 'dark'], ['daylight', 'light']]) {
  await theme(name);
  const dialog = await openDialog();
  await dialog.getByLabel('Subscription token', { exact: true }).fill('sk-ant-oat01-' + 'x'.repeat(40));
  await shot(`dialog-token-${label}`);
}
await theme('ravix');

// (b) an empty submit.
{
  const dialog = await openDialog();
  await dialog.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
  await page.waitForTimeout(600);
  await shot('dialog-empty-submit');
}

// (c) the connecting state, held by the mock for a while.
{
  const dialog = await openDialog();
  await (await context.request.post(`${mock}/__browser/credential-delay`, { data: { ms: 6000 } })).ok();
  await dialog.getByLabel('Subscription token', { exact: true }).fill('sk-ant-oat01-' + 'x'.repeat(40));
  await dialog.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
  await page.waitForTimeout(700);
  await shot('dialog-connecting');
  await dialog.locator('#project-agent-claude').getByText('Connected', { exact: true }).waitFor({ timeout: 15_000 });
  await page.waitForTimeout(400);
  await shot('dialog-connected');
  await context.request.post(`${mock}/__browser/credential-delay`, { data: { ms: 0 } });
}

await browser.close();
console.log('done');
