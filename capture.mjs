// Capture the first prompt's hand-off after setup against the dev mock.
// Usage: node tmp/screens/capture.mjs <label> [base-url]
// Writes numbered PNGs (one per observed state change) and a video to
// tmp/screens/<label>/.
import { chromium } from 'playwright';
import { mkdirSync, readdirSync, renameSync } from 'node:fs';

const label = process.argv[2] || 'run';
const base = process.argv[3] || 'http://localhost:4000';
const out = `tmp/screens/${label}`;
mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
const context = await browser.newContext({
  baseURL: base,
  viewport: { width: 1200, height: 760 },
  recordVideo: { dir: `${out}/video`, size: { width: 1200, height: 760 } },
});
const page = await context.newPage();
const connected = async () => {
  await page.locator('[data-phx-main].phx-connected').waitFor({ timeout: 30_000 });
};

// Sign in through the mock as the dedicated-opens user.
await page.goto('/');
await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
await page.getByRole('link', { name: 'Sign in as @mockuser', exact: true }).click();
await page.locator('#account-trigger').or(page.getByRole('link', { name: 'Sign out' })).first().waitFor();
await connected();
await page.locator('#project-sections[aria-busy="false"]')
  .or(page.getByRole('button', { name: 'Skip setup', exact: true })).first().waitFor();
if (new URL(page.url()).pathname.startsWith('/welcome')) {
  await page.getByRole('button', { name: 'Skip setup', exact: true }).click();
  await page.waitForURL(/\/home$/);
}

// Connect a mock Claude credential.
await page.goto('/welcome/agent');
await connected();
const status = page.locator('#agent-claude-status');
const connect = page.getByRole('button', { name: 'Connect Claude Code', exact: true });
await status.getByText('Connected').or(connect).first().waitFor();
if (await connect.isVisible()) {
  await connect.click();
  await page.getByLabel('Subscription token', { exact: true }).fill('sk-ant-oat01-browser-fixture');
  await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
  await status.getByText('Connected').waitFor();
}

// A scratch project of this run's own, then a track with a first prompt.
await page.goto('/home');
await connected();
await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
await project.getByLabel('Project name', { exact: true }).fill(`RAV-131 ${label} ${Date.now() % 10000}`);
await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
await project.waitFor({ state: 'detached' });
await page.locator('#yard .workspace-project.current .project-add').click();
const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
const prompt = dialog.getByLabel('What do you want to work on?', { exact: true });
await prompt.fill('Add a health check endpoint and document it');

// From here, watch the page and keep a frame of every distinct state.
const started = Date.now();
let last = null;
let n = 0;
const seen = [];
const observe = () => page.evaluate(() => {
  const card = document.querySelector('#track-setup-status');
  const label = document.querySelector('.workspace-queue .queue-label');
  const steps = card ? [...card.querySelectorAll('li.setup-step')].map(li => li.className.replace('setup-step ', '')) : null;
  return {
    card: card ? (card.dataset.state || 'present') : 'none',
    heading: card?.querySelector('strong')?.textContent?.trim() ?? null,
    steps,
    queue: label?.textContent?.replace(/\s+/g, ' ').trim() ?? null,
    stale: document.querySelector('.queue-stale')?.textContent?.trim() ?? null,
    turns: document.querySelectorAll('#transcript-turns .workspace-turn').length,
    chip: document.querySelector('.machine-chip .chip-label')?.textContent?.trim() ?? null,
  };
});
const snap = async (why) => {
  n += 1;
  const file = `${out}/${String(n).padStart(2, '0')}-${why}.png`;
  await page.screenshot({ path: file });
  return file;
};

await prompt.press('Enter');
await dialog.waitFor({ state: 'detached' });

const deadline = started + 150_000;
let settledAt = null;
while (Date.now() < deadline) {
  const state = await observe();
  const key = JSON.stringify(state);
  if (key !== last) {
    const t = ((Date.now() - started) / 1000).toFixed(1);
    const why = `${state.card}-${(state.queue || 'noqueue').split(' ')[0].toLowerCase().replace(/[^a-z]/g, '')}`;
    const file = await snap(why);
    console.log(`${t}s ${file}`, key);
    seen.push({ t, state });
    last = key;
  }
  const done = state.turns > 0 && state.queue === null && (state.card === 'collapsed' || state.card === 'none');
  if (done && !settledAt) settledAt = Date.now();
  if (settledAt && Date.now() - settledAt > 4_000) break;
  await page.waitForTimeout(60);
}

await context.close();
await browser.close();
for (const f of readdirSync(`${out}/video`)) renameSync(`${out}/video/${f}`, `${out}/${label}.webm`);
console.log(JSON.stringify(seen, null, 1));
