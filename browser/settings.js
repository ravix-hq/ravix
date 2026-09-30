import { expect } from '@playwright/test';

// RAV-72: a project's settings are pages in the shell, one URL a section.
// The row's gear opens the first; the frame's nav moves between them.
// RAV-74: the pages are general, access, agent, machine and danger.
export async function openProjectSettings(page, section = 'general') {
  await page.locator('#yard .workspace-project.current button[data-tip="Project settings"]').click();
  await expect(page).toHaveURL(/\/p\/[^/]+\/settings\/general$/);
  const settings = page.locator('#settings-page');
  if (section !== 'general') {
    await settings.locator(`#settings-nav-${section}`).click();
    await expect(page).toHaveURL(new RegExp(`/settings/${section}$`));
  }
  await expect(settings.locator(`#settings-section-${section}`)).toBeVisible();
  return settings;
}

// RAV-74: the Machine page's one save. The bar's Save asks first, listing
// what changes (`expectLines`) and how many tracks a rebuild closes; its
// confirmation is the save. Answers the question's text.
export async function saveMachine(page, expectLines = []) {
  const bar = page.locator('#project-machine-bar');
  await bar.getByRole('button', { name: /^Save/ }).click();
  const review = page.locator('#machine-review [role=alertdialog]');
  await expect(review).toBeVisible();
  for (const line of expectLines) await expect(review.getByRole('listitem').filter({ hasText: line })).toHaveCount(1);
  const text = await review.innerText();
  await review.locator('#confirm-machine').click();
  await expect(review).toHaveCount(0);
  await expect(bar).toBeHidden();
  return text;
}

// "New workspace…" in the switcher's menu opens a small dialog; creating
// goes to the new workspace's Members (RAV-72).
export async function createWorkspace(page, name) {
  const menu = page.locator('#workspace-menu');
  if (!(await menu.evaluate(el => el.matches(':popover-open')))) {
    await page.locator('#workspace-switcher-trigger').click();
  }
  await menu.getByRole('button', { name: 'New workspace…', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'New workspace', exact: true });
  await dialog.getByLabel('Name', { exact: true }).fill(name);
  await dialog.getByRole('button', { name: 'Create workspace', exact: true }).click();
  await expect(page).toHaveURL(/\/w\/[^/?]+\/settings\/members$/);
  await expect(dialog).toHaveCount(0);
}

// The workspace a settings page is for, as its breadcrumb names it.
export const breadcrumb = page => page.getByRole('navigation', { name: 'Breadcrumb' });

// RAV-77: an agent is connected and managed in Settings › Agents. The You
// menu's Settings opens Profile; the frame's nav moves to Agents. Returns
// the panel once Fountain has said what is held.
export async function openAgentSettings(page) {
  await page.locator('#account-trigger').click();
  await page.locator('#open-personal-settings').click();
  await expect(page).toHaveURL(/\/settings\/profile$/);
  await page.locator('#settings-nav-agents').click();
  await expect(page).toHaveURL(/\/settings\/agents$/);
  const panel = page.locator('#settings-agent-panel');
  await expect(panel.locator('.agent-card')).toHaveCount(2);
  await expect(panel.locator('.agent-card-status', { hasText: 'Checking' })).toHaveCount(0);
  return panel;
}

// Connect `agent` ('Claude Code' or 'Codex') with an API key, which is the
// card's ⋯ menu's "Connect with an API key", from Settings › Agents.
export async function connectApiKey(page, agent, key) {
  const panel = await openAgentSettings(page);
  const id = agent === 'Codex' ? 'codex' : 'claude';
  await panel.locator(`#agent-menu-${id}-trigger`).click();
  await panel.locator(`#connect-${id}-api_key`).click();
  await panel.getByLabel('API key', { exact: true }).fill(key);
  await panel.getByRole('button', { name: `Connect ${agent}`, exact: true }).click();
  await expect(panel.locator(`#agent-${id}-status`)).toContainText('Connected');
  await expect(panel.locator(`#remove-${id}-api_key`)).toBeAttached();
  return panel;
}
