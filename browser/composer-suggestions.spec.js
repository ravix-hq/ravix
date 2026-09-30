import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// The composer's `@` searches the track's files and its `/` offers the
// agent's commands and Ravix's own; both are one listbox the textarea drives
// with the keyboard, and ⌘L / Ctrl+L brings the box back from anywhere.
test('@ mentions a file, / picks a command, and Ctrl+L focuses the composer', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'mentioner', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('Mentions');
  await expect(page.locator('#project-repositories option')).not.toHaveCount(0);
  await page.getByLabel('Repository', { exact: true }).fill('mockuser/atlas-api');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  const message = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(message).toBeEnabled();
  await expect(page.locator('#transcript-status')).toHaveText('Agent replied');
  await expect(message).toHaveAttribute('placeholder', 'Ask to make changes, @mention files, run /commands');

  // Ctrl+L from elsewhere on the page.
  await page.locator('#transcript-scroll').click();
  await expect(message).not.toBeFocused();
  await page.keyboard.press('Control+l');
  await expect(message).toBeFocused();
  // The hint is for wide screens: on a narrow track it would wrap the
  // composer's row and take room from the transcript.
  await expect(page.locator('#composer-shortcut')).toBeVisible();
  await page.setViewportSize({ width: 535, height: 900 });
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
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowUp');
  await page.keyboard.press('Enter');
  await expect(message).toHaveValue('Look at @src/router.ts ');
  await expect(list).toBeHidden();

  // Escape closes the list and leaves the words.
  await message.pressSequentially('and @');
  await expect(page.getByRole('listbox', { name: 'Files to mention' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.locator('#composer-suggestions')).toBeHidden();
  await expect(message).toHaveValue('Look at @src/router.ts and @');

  // `/`: the agent's commands, then Ravix's.
  await message.fill('');
  await message.pressSequentially('/');
  const commands = page.getByRole('listbox', { name: 'Commands' });
  await expect(commands.getByRole('option', { name: /\/review/ })).toBeVisible();
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
  await expect(page.locator('button[phx-click=panel][phx-value-name=changes]')).toHaveClass(/selected/);
  await expect(message).toHaveValue('');
  await expect(page.locator('#transcript-turns > article')).toHaveCount(turns);
});
