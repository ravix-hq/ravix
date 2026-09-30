import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { connectApiKey } from './settings.js';

// RAV-52 on Fountain ADR 0062: the model menu offers what the runtime
// advertised (`session_config_options`), every prompt carries the thread's
// `session_config`, and each turn reports what was applied, skipped or
// refused. Nothing is ever sent as an `/effort` or `/fast` prompt turn.

async function newTrack(page, name, agent) {
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill(name);
  if (agent) await project.locator(`#project-agent-${agent}`).click();
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'New track', exact: true })).toHaveCount(0);
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  await expect(page.locator('#model-trigger')).toBeEnabled({ timeout: 30_000 });
}

async function send(page, text) {
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill(text);
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.locator('#transcript-turns')).toContainText(text, { timeout: 30_000 });
  await expect(page.locator('#model-trigger')).toBeEnabled({ timeout: 30_000 });
}

test('a Claude thread sets effort and Fast from the advertised options, per turn', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'modeleffort', '/home');
  await connectClaude(page);
  await newTrack(page, 'Claude effort');

  const trigger = page.locator('#model-trigger');
  const menu = page.getByRole('menu', { name: 'Model', exact: true });
  const effort = menu.getByRole('group', { name: 'Effort', exact: true });
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Opus 5.5 · Default');

  await trigger.click();
  await expect(effort.locator('[role=menuitemradio] .truncate')).toHaveText(['Default', 'Low', 'Medium', 'High', 'Extra high', 'Max']);
  await expect(effort.getByRole('menuitemradio', { name: 'Default', exact: true })).toHaveAttribute('aria-checked', 'true');
  await effort.getByRole('menuitemradio', { name: 'High', exact: true }).click();
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Opus 5.5 · High');

  await trigger.click();
  const fast = menu.getByRole('menuitemcheckbox', { name: 'Fast mode' });
  await expect(fast).toHaveAttribute('aria-checked', 'false');
  await fast.click();
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Opus 5.5 · High · Fast mode');

  await send(page, 'Think hard about this');
  const turns = page.locator('#transcript-turns');
  await expect(turns.locator('.turn-config').last()).toHaveText('High · Fast mode', { timeout: 30_000 });
  await expect(turns).not.toContainText('/effort');
  await expect(turns).not.toContainText('/fast');

  // Max is Opus's; Sonnet lists no Max. The menu shows the options of the
  // latest turn, so Max is still offered after the switch, and the runtime
  // refuses it: the turn fails before the prompt, saying so.
  await trigger.click();
  await effort.getByRole('menuitemradio', { name: 'Max', exact: true }).click();
  await trigger.click();
  await menu.getByRole('menuitemradio', { name: /Claude Sonnet 5/ }).click();
  await expect(trigger).toHaveAttribute('title', /Claude Sonnet 5 · Max/);
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill('Now on Sonnet');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  const refusal = turns.locator('.workspace-failure').last();
  await expect(refusal).toContainText("Setting not accepted, so the message wasn't sent", { timeout: 30_000 });
  await expect(refusal).toContainText('Invalid value for config option effort: max');
  await expect(turns).not.toContainText('Reply failed');

  // "Change setting" opens the menu, now with Sonnet's own list.
  await expect(trigger).toBeEnabled({ timeout: 30_000 });
  await refusal.getByRole('button', { name: 'Change setting', exact: true }).click();
  await expect(effort.locator('[role=menuitemradio] .truncate')).toHaveText(['Default', 'Low', 'Medium', 'High']);
  await expect(menu.getByRole('menuitemcheckbox')).toHaveCount(0);
  await effort.getByRole('menuitemradio', { name: 'High', exact: true }).click();
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Sonnet 5 · High');
});

test('a Codex thread gets effort and Fast under its own option ids', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'modeleffort', '/home');
  await connectApiKey(page, 'Codex', 'mock-model-effort-key');
  await newTrack(page, 'Codex effort', 'codex');

  const trigger = page.locator('#model-trigger');
  const menu = page.getByRole('menu', { name: 'Model', exact: true });
  const effort = menu.getByRole('group', { name: 'Reasoning effort', exact: true });
  await trigger.click();
  await expect(effort.locator('[role=menuitemradio] .truncate')).toHaveText(['Low', 'Medium', 'High', 'Extra high']);
  await effort.getByRole('menuitemradio', { name: 'Extra high', exact: true }).click();
  await trigger.click();
  await menu.getByRole('menuitemcheckbox', { name: 'Fast mode' }).click();
  await expect(trigger).toHaveAttribute('title', /· Extra high · Fast mode$/);

  await send(page, 'Plan the refactor');
  await expect(page.locator('#transcript-turns .turn-config').last()).toHaveText('Extra high · Fast mode', { timeout: 30_000 });
});
