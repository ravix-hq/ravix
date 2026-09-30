import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// RAV-87: while a turn runs, Stop takes the send button's place instead of
// adding a row under the composer, so the composer keeps its height when a
// turn starts and ends, and Stop is reachable from the keyboard.
test('Stop replaces send in place while the agent works, without resizing the composer', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('In-place stop');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
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
  const height = async () => (await box.boundingBox()).height;

  // Idle: send, no Stop.
  await expect(send).toBeVisible();
  await expect(stop).toHaveCount(0);
  const idle = await height();
  const sendAt = await send.boundingBox();

  await composer.fill('Demonstrate a long-running turn');
  await composer.press('Enter');

  // Working, empty box: Stop alone, where send was, and the same size.
  await expect(stop).toBeVisible({ timeout: 30_000 });
  await expect(composer).toHaveValue('');
  await expect(send).toBeHidden();
  const stopAt = await stop.boundingBox();
  expect(stopAt.x).toBeCloseTo(sendAt.x, 0);
  expect(stopAt.y).toBeCloseTo(sendAt.y, 0);
  expect(stopAt.width).toBeCloseTo(sendAt.width, 0);
  expect(stopAt.height).toBeCloseTo(sendAt.height, 0);
  expect(await height()).toBe(idle);
  await expect(stop.locator('svg')).toBeVisible();

  // The model is waiting on the turn, not unavailable: full contrast, and
  // its title says why it cannot change.
  const model = page.locator('#model-trigger');
  if (await model.count()) {
    await expect(model).toBeDisabled();
    await expect(model).toHaveAttribute('title', /\nCan't change while the agent is working$/);
    expect(Number(await model.evaluate(el => getComputedStyle(el).opacity))).toBe(1);
  }

  // Working with text typed: send comes back in its place to queue it, and
  // Stop sits to its left. Still the same height.
  await composer.fill('Queue this next');
  await expect(send).toBeVisible();
  const both = { send: await send.boundingBox(), stop: await stop.boundingBox() };
  expect(both.send.x).toBeCloseTo(sendAt.x, 0);
  expect(both.stop.x + both.stop.width).toBeLessThanOrEqual(both.send.x);
  expect(both.stop.y).toBeCloseTo(both.send.y, 0);
  expect(await height()).toBe(idle);
  await composer.fill('');
  await expect(send).toBeHidden();

  // Keyboard: Tab from the message box reaches Stop, and Enter stops the turn.
  await composer.focus();
  let reached = false;
  for (let i = 0; i < 12 && !reached; i++) {
    await page.keyboard.press('Tab');
    reached = await stop.evaluate(el => el === document.activeElement);
  }
  expect(reached).toBe(true);
  await page.keyboard.press('Enter');

  // Turn over: send is back where it was, and the composer never moved.
  await expect(stop).toHaveCount(0, { timeout: 30_000 });
  await expect(send).toBeVisible();
  const after = await send.boundingBox();
  expect(after.x).toBeCloseTo(sendAt.x, 0);
  expect(after.y).toBeCloseTo(sendAt.y, 0);
  expect(await height()).toBe(idle);
});
