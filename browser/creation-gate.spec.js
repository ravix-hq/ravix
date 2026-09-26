import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';

test('connect Codex inline without losing the new project draft', async ({ page }) => {
  await signIn(page, 'dana', '/home');
  await page.getByRole('button', { name: /^Quick start/ }).click();
  const dialog = page.getByRole('dialog', { name: 'New project' });
  await dialog.getByLabel('Project name', { exact: true }).fill('Credential gate');
  await dialog.locator('#project-agent-codex').click();
  await expect(dialog.locator('#project-agent-codex')).toContainText('Not connected');
  await expect(dialog.getByRole('button', { name: 'Create project', exact: true })).toBeDisabled();
  await dialog.getByRole('button', { name: 'API key', exact: true }).click();
  await page.evaluate(() => Promise.all(document.getAnimations()
    .filter(a => a.effect?.getTiming?.().iterations !== Infinity)
    .map(a => a.finished.catch(() => {}))));
  const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(axe.violations).toEqual([]);
  await dialog.getByLabel('API key', { exact: true }).fill('sk-browser-codex-fixture');
  await dialog.getByRole('button', { name: 'Connect Codex', exact: true }).click();
  await expect(dialog.locator('#project-agent-codex')).toContainText('Connected');
  await expect(dialog.locator('#project-agent-codex')).toHaveAttribute('aria-pressed', 'true');
  await expect(dialog.getByLabel('Project name', { exact: true })).toHaveValue('Credential gate');
  await expect(dialog.getByRole('button', { name: 'Create project', exact: true })).toBeEnabled();
  await dialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(dialog).not.toBeVisible();
  await expect(page.locator('.crumbs')).toContainText('Credential gate');
});

test('late dialog focus never steals typing from the project name', async ({ page }) => {
  await signIn(page, 'dana', '/home');
  await page.getByRole('button', { name: /^Open a GitHub project/ }).click();
  const dialog = page.getByRole('dialog', { name: 'New project' });
  await expect(dialog.getByRole('combobox', { name: 'Repository', exact: true })).toBeFocused();
  const name = dialog.getByLabel('Project name', { exact: true });
  await name.fill('Draft');
  // Replay the mounted focus command after a person has already chosen a
  // field: on a busy browser its queued animation frame can run this late.
  await page.evaluate(async () => {
    const element = document.querySelector('#new-project-dialog-dialog');
    const command = element.getAttribute('phx-mounted');
    if (command) window.liveSocket.execJS(element, command);
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  });
  await expect(name).toBeFocused();
  await page.keyboard.type(' kept');
  await expect(name).toHaveValue('Draft kept');
  await expect(dialog.getByRole('combobox', { name: 'Repository', exact: true })).toHaveValue('');
});
