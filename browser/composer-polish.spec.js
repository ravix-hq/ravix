import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-94: the composer's focus hint gives way to the focused box (and to a
// window under 1360px), Ask agent / Comment switches without waiting for the
// server and without changing the box's size, the action row is one line of
// 28px controls at 1280px (and on a phone), and a queued prompt is a muted
// bubble with Edit and Cancel.
test('the composer switches mode at once, keeps one row, and hides its hint while focused', async ({ page }) => {
  test.setTimeout(120_000);
  // Wide enough that, beside the sidebar, the thread list and the inspector,
  // the composer's row still has room for its hint (it had at 1440px when
  // the conversation stood beside the rail alone).
  await page.setViewportSize({ width: 1920, height: 800 });
  await signIn(page, 'dana');
  await connectClaude(page);
  await openAddRepository(page);
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Composer polish');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#top-new-track').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  const message = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(message).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });

  const box = page.locator('#composer-form .composer-box');
  const textarea = page.locator('#composer-form textarea');
  const hint = page.locator('#composer-shortcut');
  const height = async () => (await box.boundingBox()).height;
  // Every visible control in the action row shares one line: each one's
  // top is above every other one's bottom.
  const oneLine = () => page.locator('#composer-form .workspace-actions').evaluate(row => {
    const boxes = [...row.children]
      .filter(el => el.offsetParent && getComputedStyle(el).display !== 'none')
      .map(el => el.getBoundingClientRect())
      .filter(r => r.height > 0 && r.width > 0);
    return boxes.every(a => boxes.every(b => a.top < b.bottom && b.top < a.bottom));
  });

  // The focus hint is there until the box has focus, and holds its place.
  await page.locator('#transcript, .transcript-scroll').first().click({ position: { x: 20, y: 20 } });
  await expect(textarea).not.toBeFocused();
  await expect(hint).toBeVisible();
  const hintAt = await hint.boundingBox();
  await textarea.focus();
  await expect(hint).toBeHidden();
  expect(await hint.evaluate(el => getComputedStyle(el).visibility)).toBe('hidden');
  expect(await hint.boundingBox()).toEqual(hintAt);
  await textarea.blur();
  await expect(hint).toBeVisible();

  // At 1280px there is no room for it; the row is one line of 28px controls.
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(hint).toBeHidden();
  expect(await oneLine()).toBe(true);
  const heights = await page.locator('#composer-form .workspace-actions').evaluate(row =>
    [...row.querySelectorAll(':scope > button, :scope > .composer-mode, :scope > .composer-model, #model-trigger')]
      .filter(el => el.offsetParent)
      .map(el => [el.id || el.className, el.getBoundingClientRect().height]));
  expect(heights.map(([name]) => name).join(' ')).toMatch(/model-trigger|composer-model/);
  for (const [, h] of heights) expect(h).toBe(28);
  const idle = await height();

  // Comment: pressed, coloured and relabelled in the same task as the click,
  // which no answer from the server can arrive inside.
  const switched = await page.evaluate(() => {
    document.querySelector('#composer-mode-comment').click();
    const textarea = document.querySelector('#composer-form textarea');
    return {
      pressed: document.querySelector('#composer-mode-comment').getAttribute('aria-pressed'),
      commenting: document.querySelector('#composer-form .composer-box').classList.contains('commenting'),
      label: textarea.getAttribute('aria-label'),
      placeholder: textarea.placeholder,
      send: document.querySelector('#composer-send').getAttribute('aria-label'),
      hint: getComputedStyle(document.querySelector('#composer-mode-hint')).display,
      drawn: textarea.dataset.mode,
    };
  });
  expect(switched).toEqual({
    pressed: 'true',
    commenting: true,
    label: 'Comment',
    placeholder: 'Comment for people on this thread, @mention someone',
    send: 'Post comment',
    hint: 'flex',
    drawn: 'ask',
  });
  // The server agrees, and the look it draws is the same one.
  await expect(textarea).toHaveAttribute('data-mode', 'comment');
  await expect(page.locator('#composer-mode-comment')).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#composer-mode-hint')).toBeVisible();
  await expect(page.locator('#model-trigger, .composer-model').first()).toBeHidden();
  expect(await height()).toBe(idle);
  expect(await oneLine()).toBe(true);

  // Back to Ask, just as quickly.
  const back = await page.evaluate(() => {
    document.querySelector('#composer-mode-ask').click();
    return {
      pressed: document.querySelector('#composer-mode-ask').getAttribute('aria-pressed'),
      commenting: document.querySelector('#composer-form .composer-box').classList.contains('commenting'),
      label: document.querySelector('#composer-form textarea').getAttribute('aria-label'),
    };
  });
  expect(back).toEqual({ pressed: 'true', commenting: false, label: 'Message' });
  await expect(textarea).toHaveAttribute('data-mode', 'ask');
  expect(await height()).toBe(idle);

  // Running, with Stop and send both in the row: still one line, and the
  // box says a prompt now waits for the turn.
  await message.fill('Demonstrate a long-running turn');
  await message.press('Enter');
  await expect(page.locator('#composer-stop')).toBeVisible({ timeout: 30_000 });
  await expect(message).toHaveAttribute('placeholder', 'Add a follow up');
  await message.fill('Then update the changelog');
  await expect(page.locator('#composer-send')).toBeEnabled();
  expect(await oneLine()).toBe(true);
  expect(await height()).toBe(idle);

  // Queued: a muted bubble at the right, as the prompt will be, saying what
  // it waits for, with Edit and Cancel.
  await message.press('Enter');
  const row = page.getByRole('list', { name: 'Queued prompts' }).getByRole('listitem');
  await expect(row).toHaveCount(1);
  await expect(row.locator('.queue-label')).toHaveText('Queued · sends when the agent is free');
  const bubble = row.locator('.queue-prompt');
  await expect(bubble).toContainText('Then update the changelog');
  expect(await bubble.evaluate(el => getComputedStyle(el).borderTopStyle)).toBe('dashed');
  const composerBox = await box.boundingBox();
  const bubbleBox = await bubble.boundingBox();
  expect(composerBox.x + composerBox.width - (bubbleBox.x + bubbleBox.width)).toBeLessThan(24);
  await expect(row.getByRole('button', { name: 'Cancel', exact: true })).toBeVisible();

  // Edit takes it off the queue and puts its words back in the box.
  await row.getByRole('button', { name: 'Edit', exact: true }).click();
  await expect(message).toHaveValue('Then update the changelog');
  await expect(row).toHaveCount(0);

  // A phone: the row still does not wrap.
  await page.setViewportSize({ width: 390, height: 800 });
  await expect.poll(oneLine).toBe(true);
});
