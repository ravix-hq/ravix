import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { connectApiKey } from './settings.js';

// RAV-52 on Fountain ADR 0062: the model menu offers what the runtime
// advertised (`session_config_options`), every prompt carries the thread's
// `session_config`, and each turn reports what was applied, skipped or
// refused. Nothing is ever sent as an `/effort` or `/fast` prompt turn.
// The Claude mock names its top level "Xhigh", as the adapter does, and the
// menu says "Extra high" (RAV-95).

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
  const menu = page.getByRole('dialog', { name: 'Model', exact: true });
  const effort = menu.getByRole('radiogroup', { name: 'Effort', exact: true });
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Opus 5.5 · Default');

  await trigger.click();
  await expect(effort.locator('[role=radio] .truncate')).toHaveText(['Default', 'Low', 'Medium', 'High', 'Extra high', 'Max']);
  await expect(effort.getByRole('radio', { name: 'Default', exact: true })).toHaveAttribute('aria-checked', 'true');
  await effort.getByRole('radio', { name: 'High', exact: true }).click();
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Opus 5.5 · High');

  // RAV-95: sections, and Fast a switch that stays in the open menu.
  await trigger.click();
  await expect(menu.locator('.model-section-label')).toHaveText(['Model', 'Effort', 'Speed']);
  await expect(menu.locator('.model-default-hint')).toHaveText('Also your default for new threads');
  expect((await new AxeBuilder({ page }).include('#model-menu').withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  const fast = menu.getByRole('switch', { name: 'Fast mode' });
  await expect(fast).toHaveAttribute('aria-checked', 'false');
  await fast.click();
  await expect(fast).toHaveAttribute('aria-checked', 'true');
  await expect(menu).toBeVisible();
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Opus 5.5 · High · Fast mode');
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();

  await send(page, 'Think hard about this');
  const turns = page.locator('#transcript-turns');
  await expect(turns.locator('.turn-config').last()).toHaveText('High · Fast mode', { timeout: 30_000 });
  await expect(turns).not.toContainText('/effort');
  await expect(turns).not.toContainText('/fast');

  // Max is Opus's; Sonnet lists no Max. The menu shows the options of the
  // latest turn, so Max is still offered after the switch, and the runtime
  // refuses it: the turn fails before the prompt, saying so.
  await trigger.click();
  await effort.getByRole('radio', { name: 'Max', exact: true }).click();
  await trigger.click();
  await menu.getByRole('radio', { name: /Claude Sonnet 5/ }).click();
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
  await expect(effort.locator('[role=radio] .truncate')).toHaveText(['Default', 'Low', 'Medium', 'High']);
  // Sonnet has no fast tier: the switch is there, off and disabled, saying why.
  const noFast = menu.getByRole('switch', { name: 'Fast mode' });
  await expect(noFast).toHaveAttribute('aria-checked', 'false');
  await expect(noFast).toHaveAttribute('aria-disabled', 'true');
  await expect(noFast).toHaveAttribute('title', 'Not available for this model');

  await effort.getByRole('radio', { name: 'High', exact: true }).click();
  await expect(trigger).toHaveAttribute('title', 'Claude Code · Claude Sonnet 5 · High');
});

test('a Codex thread gets effort and Fast under its own option ids', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'modeleffort', '/home');
  await connectApiKey(page, 'Codex', 'mock-model-effort-key');
  await newTrack(page, 'Codex effort', 'codex');

  const trigger = page.locator('#model-trigger');
  const menu = page.getByRole('dialog', { name: 'Model', exact: true });
  const effort = menu.getByRole('radiogroup', { name: 'Effort', exact: true });
  await trigger.click();
  await expect(effort.locator('[role=radio] .truncate')).toHaveText(['Low', 'Medium', 'High', 'Extra high']);
  await effort.getByRole('radio', { name: 'Extra high', exact: true }).click();
  await trigger.click();
  await menu.getByRole('switch', { name: 'Fast mode' }).click();
  await expect(trigger).toHaveAttribute('title', /· Extra high · Fast mode$/);
  await page.keyboard.press('Escape');

  await send(page, 'Plan the refactor');
  await expect(page.locator('#transcript-turns .turn-config').last()).toHaveText('Extra high · Fast mode', { timeout: 30_000 });
});
