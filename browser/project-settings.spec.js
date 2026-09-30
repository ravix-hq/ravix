import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { saveMachine } from './settings.js';

const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;

// RAV-74: a project's settings are five pages. The Machine page gathers the
// setup, packages, variables, secrets and run script behind one Save &
// rebuild that says first what changes and how many open tracks close. The
// dialog's old tabs land on the part of the page they became, and Settings
// is reachable from the project header and the open project's ⋯ menu.
test('Machine saves everything behind one Save & rebuild; old tabs land on their part', async ({ page, request }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const create = page.getByRole('dialog', { name: 'Add a repository' });
  await create.getByLabel('Project name', { exact: true }).fill('Machine page browser');
  await create.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(create).not.toBeVisible();
  const projectPath = new URL(page.url()).pathname;

  // The entry points: the header's Settings, and the ⋯ menu without a hover.
  await expect(page.locator('#crumb-settings')).toHaveAttribute('href', `${projectPath}/settings/general`);
  const more = page.locator('#yard .workspace-project.current button[data-tip="More"]');
  await page.mouse.move(900, 600);
  await expect(more).toHaveCSS('opacity', '1');
  await more.click();
  await page.getByRole('menuitem', { name: /^Settings for / }).click();
  await expect(page).toHaveURL(new RegExp(`${projectPath}/settings/general$`));

  // A track to be closed by the rebuild.
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  const trackPath = new URL(page.url()).pathname;

  // The old Secrets tab opens the Machine page at its secrets.
  await page.goto(`${projectPath}/settings/secrets`);
  await expect(page).toHaveURL(new RegExp(`${projectPath}/settings/machine#machine-secrets$`));
  const settings = page.locator('#settings-page');
  await expect(settings.locator('#settings-nav-machine')).toHaveAttribute('aria-current', 'page');
  await expect(settings.locator('#machine-secrets')).toBeInViewport();

  const bar = page.locator('#project-machine-bar');
  await expect(bar).toBeHidden();
  await settings.getByLabel('Setup script', { exact: true }).fill('npm ci');
  await settings.getByLabel('apt packages', { exact: true }).fill('jq');
  await settings.getByRole('button', { name: 'Add variable', exact: true }).click();
  await settings.getByLabel('Variable name', { exact: true }).fill('NODE_ENV');
  await settings.getByLabel('Variable value', { exact: true }).fill('test');
  await settings.getByRole('button', { name: 'Add secret', exact: true }).click();
  await settings.getByLabel('Secret name', { exact: true }).fill('BROWSER_SECRET');
  await settings.getByLabel('Secret value', { exact: true }).fill('browser-fixture-value');
  await expect(bar.getByRole('button', { name: 'Save & rebuild', exact: true })).toBeVisible();

  // Cancel asks nothing more and loses nothing typed.
  await bar.getByRole('button', { name: 'Save & rebuild', exact: true }).click();
  const review = page.getByRole('alertdialog', { name: 'Save and rebuild the machine?' });
  await expect(review.getByRole('listitem')).toHaveText(['+jq in apt', 'setup script edited', '1 variable added', '1 secret added']);
  await expect(review).toContainText('Rebuild closes 1 open track');
  await expect(review.getByRole('button', { name: 'Save & rebuild', exact: true })).toBeFocused();
  const axe = await new AxeBuilder({ page }).include('#settings-page')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(review).toHaveCount(0);
  await expect(settings.getByLabel('Secret value', { exact: true })).toHaveValue('browser-fixture-value');

  const text = await saveMachine(page, ['+jq in apt', '1 secret added']);
  expect(text).not.toContain('browser-fixture-value');
  await expect(page.getByText('Machine settings saved. The machine is being rebuilt.', { exact: true })).toBeVisible();
  await expect(settings.locator('#secret-keys')).toContainText('BROWSER_SECRET');
  await expect(page.locator('body')).not.toContainText('browser-fixture-value');
  const environments = (await (await request.get(`${mock}/api/environments`)).json()).data;
  const env = environments.find(e => e.env_vars?.NODE_ENV === 'test');
  expect(env.setup_script).toBe('npm ci');
  expect(env.packages).toEqual({ apt: ['jq'] });
  // The rebuild closed the track.
  await page.goto(trackPath);
  await expect(page).not.toHaveURL(new RegExp(`${trackPath}$`));
});
