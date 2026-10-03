import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// The composer's `@` searches the track's files and its `/` offers the
// agent's commands and Ravix's own; both are one listbox the textarea drives
// with the keyboard, and ⌘L / Ctrl+L brings the box back from anywhere.
test('@ mentions a file, / picks a command, and Ctrl+L focuses the composer', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'mentioner', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  await page.getByLabel('Project name', { exact: true }).fill('Mentions');
  await expect(page.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await page.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await page.getByRole('dialog', { name: 'Add a repository' }).getByRole('button', { name: 'Add repository', exact: true }).click();
  await page.locator('#top-new-track').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  const message = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(message).toBeEnabled();
  await expect(page.locator('#transcript-status')).toHaveText('Agent replied');
  await expect(message).toHaveAttribute('placeholder', 'Ask to make changes, @mention files, run /commands');

  // Ctrl+L from elsewhere on the page. The hint shows once the composer has
  // room for it: beside the sidebar, threads and inspector, at 1920px.
  await page.setViewportSize({ width: 1920, height: 900 });
  await page.locator('#transcript-scroll').click();
  await expect(page.locator('#composer-shortcut')).toBeVisible();
  await expect(message).not.toBeFocused();
  await page.keyboard.press('Control+l');
  await expect(message).toBeFocused();
  // The hint is for reaching the box, so it goes once the box has focus
  // (RAV-94), and it is for wide screens: below 1360px it would wrap the
  // composer's row and take room from the transcript.
  await expect(page.locator('#composer-shortcut')).toBeHidden();
  await message.blur();
  await expect(page.locator('#composer-shortcut')).toBeVisible();
  await page.setViewportSize({ width: 1280, height: 900 });
  await expect(page.locator('#composer-shortcut')).toBeHidden();
  await page.setViewportSize({ width: 1280, height: 720 });
  await message.focus();

  // `@`: the files arrive from the track's worktree, and typing narrows them.
  const list = page.getByRole('listbox', { name: 'Files to mention' });
  await message.pressSequentially('Look at @rout');
  await expect(list).toBeVisible();
  await expect(list.getByRole('option').first()).toHaveText(/router\.tssrc\//);
  await expect(page.locator('#composer-suggestions-status')).toHaveText(/files?\. Up and down to choose/);
  const first = await list.getByRole('option').first().getAttribute('id');
  await expect(message).toHaveAttribute('aria-activedescendant', first);
  // RAV-95: on the composer's own edges, and no "@you is typing…" beside it.
  const box = await page.locator('.composer-box').boundingBox();
  const shown = await list.boundingBox();
  expect(Math.abs(shown.x - box.x)).toBeLessThanOrEqual(0.5);
  expect(Math.abs(shown.width - box.width)).toBeLessThanOrEqual(0.5);
  await expect(page.getByText(/@mentioner is typing/)).toHaveCount(0);
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowUp');
  await page.keyboard.press('Enter');
  await expect(message).toHaveValue('Look at @src/router.ts ');
  await expect(list).toBeHidden();

  // Escape closes the list and leaves the words.
  await message.pressSequentially('and @zzqq');
  await expect(list.locator('[aria-disabled=true]')).toHaveText('No files match');
  await expect(list).not.toHaveAttribute('aria-busy', 'true');
  for (let i = 0; i < 4; i++) await page.keyboard.press('Backspace');
  await expect(page.getByRole('listbox', { name: 'Files to mention' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.locator('#composer-suggestions')).toBeHidden();
  await expect(message).toHaveValue('Look at @src/router.ts and @');

  // `/`: the agent's commands, then Ravix's. Opening the list moves
  // nothing behind it, and the row Enter would pick is highlighted.
  await message.fill('');
  const transcript = page.locator('#transcript-scroll');
  await transcript.evaluate(el => { el.scrollTop = el.scrollHeight; });
  const scrolled = await transcript.evaluate(el => el.scrollTop);
  await message.pressSequentially('/');
  const commands = page.getByRole('listbox', { name: 'Commands' });
  await expect(commands.getByRole('option', { name: /\/review/ })).toBeVisible();
  expect(await transcript.evaluate(el => el.scrollTop)).toBe(scrolled);
  const top = commands.getByRole('option').first();
  await expect(top).toHaveAttribute('aria-selected', 'true');
  await expect(message).toHaveAttribute('aria-activedescendant', await top.getAttribute('id'));
  await page.keyboard.press('ArrowDown');
  await expect(commands.getByRole('option').nth(1)).toHaveAttribute('aria-selected', 'true');
  await expect(top).toHaveAttribute('aria-selected', 'false');
  await page.keyboard.press('ArrowUp');
  // Skills read as their purpose, not "Use this skill when…".
  await expect(commands.getByRole('option', { name: /\/sprite/ })).toContainText('Users are modifying system configuration');
  await expect(commands).not.toContainText(/Use (this skill )?when\b/);
  // Eight whole rows, then it scrolls; the eighth is not cut off.
  const fit = await commands.evaluate(el => {
    const rows = [...el.querySelectorAll('[role=option]')];
    const list = el.getBoundingClientRect();
    const eighth = rows[7].getBoundingClientRect();
    return { rows: rows.length, scrolls: el.scrollHeight > el.clientHeight,
      eighthInside: eighth.bottom <= list.bottom - 1, ninthBelow: rows[8].getBoundingClientRect().top >= list.bottom - 6 };
  });
  expect(fit).toEqual({ rows: fit.rows, scrolls: true, eighthInside: true, ninthBelow: true });
  expect(fit.rows).toBeGreaterThan(8);
  await expect(commands.getByRole('option', { name: /\/changes.*Ravix/ })).toBeVisible();
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await message.pressSequentially('rev');
  await page.keyboard.press('Enter');
  await expect(message).toHaveValue('/review ');

  // A Ravix command is the button it stands for, and nothing is sent.
  const turns = await page.locator('#transcript-turns > article').count();
  await message.fill('');
  await message.pressSequentially('/chan');
  await page.keyboard.press('Enter');
  await expect(page.locator('#track-tab-changes')).toHaveAttribute('aria-pressed', 'true');
  // Changes takes the page; the composer, out of sight, is left empty.
  await expect(page.locator('#composer-form textarea')).toHaveValue('');
  await expect(page.locator('#transcript-turns > article')).toHaveCount(turns);
});
