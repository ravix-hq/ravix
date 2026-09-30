import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// RAV-87: the send slot has three states --- idle and empty (send disabled),
// idle with text (send enabled), and a running turn (Stop in the same slot,
// with send beside it once something is typed). None of them moves the
// composer: its top edge and height are the same in every one. Stop follows
// the shown thread's tab, so the two never disagree, and it is reachable
// from the keyboard.
test('Stop replaces send in place while the agent works, without moving the composer', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('In-place stop');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });

  const form = page.locator('#composer-form');
  const box = page.locator('#composer-form .composer-box');
  const send = form.getByRole('button', { name: 'Send', exact: true });
  const stop = form.getByRole('button', { name: 'Stop agent', exact: true });
  const tab = page.locator('#thread-tablist [role=tab][aria-selected=true]');
  const footprint = async () => {
    const { y, height } = await box.boundingBox();
    return { top: y, height };
  };

  // Every DOM change from here on records whether Stop is drawn and whether
  // the shown thread's tab says Running. They must never disagree.
  await expect(tab).toBeVisible();
  await page.evaluate(() => {
    window.slotRecord = [];
    const read = () => {
      const label = document.querySelector('#thread-tablist [role=tab][aria-selected=true]')?.getAttribute('aria-label') ?? '';
      window.slotRecord.push({ running: label.includes('· Running'), stop: !!document.querySelector('#composer-stop') });
    };
    new MutationObserver(read).observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    read();
  });

  // 1. Idle, empty: send is disabled, and there is no Stop.
  await expect(send).toBeVisible();
  await expect(send).toBeDisabled();
  await expect(stop).toHaveCount(0);
  const idle = await footprint();
  const sendAt = await send.boundingBox();

  // 2. Idle, with text: send is enabled.
  await composer.fill('Demonstrate a long-running turn');
  await expect(send).toBeEnabled();
  expect(await footprint()).toEqual(idle);
  await composer.press('Enter');

  // 3. Running, empty: Stop alone, where send was, and the same size; the
  // composer has not moved.
  await expect(stop).toBeVisible({ timeout: 30_000 });
  await expect(tab).toHaveAttribute('aria-label', /· Running/);
  await expect(composer).toHaveValue('');
  await expect(send).toHaveCount(0);
  const stopAt = await stop.boundingBox();
  expect(stopAt.x).toBeCloseTo(sendAt.x, 0);
  expect(stopAt.y).toBeCloseTo(sendAt.y, 0);
  expect(stopAt.width).toBeCloseTo(sendAt.width, 0);
  expect(stopAt.height).toBeCloseTo(sendAt.height, 0);
  expect(await footprint()).toEqual(idle);
  await expect(stop.locator('svg')).toBeVisible();

  // The model is waiting on the turn, not unavailable: full contrast, and
  // its title says why it cannot change.
  const model = page.locator('#model-trigger');
  if (await model.count()) {
    await expect(model).toBeDisabled();
    await expect(model).toHaveAttribute('title', /\nCan't change while the agent is working$/);
    expect(Number(await model.evaluate(el => getComputedStyle(el).opacity))).toBe(1);
  }

  // Running, with text typed: send comes back in its place, enabled, to
  // queue it, and Stop sits to its left. Still not moved.
  await composer.fill('Queue this next');
  await expect(send).toBeEnabled();
  const both = { send: await send.boundingBox(), stop: await stop.boundingBox() };
  expect(both.send.x).toBeCloseTo(sendAt.x, 0);
  expect(both.stop.x + both.stop.width).toBeLessThanOrEqual(both.send.x);
  expect(both.stop.y).toBeCloseTo(both.send.y, 0);
  expect(await footprint()).toEqual(idle);
  await composer.fill('');
  await expect(send).toHaveCount(0);

  // Keyboard: Tab from the message box reaches Stop, and Enter stops the turn.
  await composer.focus();
  let reached = false;
  for (let i = 0; i < 12 && !reached; i++) {
    await page.keyboard.press('Tab');
    reached = await stop.evaluate(el => el === document.activeElement);
  }
  expect(reached).toBe(true);
  await page.keyboard.press('Enter');

  // Turn over: the tab and the slot go back together, send is disabled
  // where it was, and the composer never moved.
  await expect(stop).toHaveCount(0, { timeout: 30_000 });
  await expect(tab).not.toHaveAttribute('aria-label', /· Running/);
  await expect(send).toBeDisabled();
  const after = await send.boundingBox();
  expect(after.x).toBeCloseTo(sendAt.x, 0);
  expect(after.y).toBeCloseTo(sendAt.y, 0);
  expect(await footprint()).toEqual(idle);

  const record = await page.evaluate(() => window.slotRecord);
  expect(record.some(r => r.running && r.stop)).toBe(true);
  expect(record.some(r => !r.running && !r.stop)).toBe(true);
  expect(record.filter(r => r.running !== r.stop)).toEqual([]);
});
