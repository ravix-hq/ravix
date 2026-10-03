import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// A comment is for people and never for the agent: the composer says which it
// is sending, the comment lands inline after the turn it followed, and only
// its author can edit or delete it.
test('comments post inline, edit and delete at desktop and narrow widths', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'commenter', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  await page.getByLabel('Project name', { exact: true }).fill('Comments');
  await expect(page.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await page.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await page.getByRole('dialog', { name: 'Add a repository' }).getByRole('button', { name: 'Add repository', exact: true }).click();
  await page.locator('#top-new-track').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();
  await expect(page.locator('#transcript-status')).toHaveText('Agent replied');
  const message = page.getByRole('textbox', { name: 'Message', exact: true });
  await message.fill('Explain this project');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  const reply = page.locator('.workspace-turn').filter({ hasText: 'Explain this project' });
  await expect(reply.locator('.agent-terminal-output')).toContainText('There is one TODO worth doing here', { timeout: 20_000 });
  const turns = await page.locator('#transcript-turns > article').count();

  for (const width of [1280, 500]) {
    await page.setViewportSize({ width, height: 900 });
    const text = `Reviewed at ${width}px, **looks right**`;

    await page.getByRole('button', { name: 'Comment', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Comment', exact: true })).toHaveAttribute('aria-pressed', 'true');
    const box = page.getByRole('textbox', { name: 'Comment', exact: true });
    await expect(box).toBeVisible();
    await expect(page.locator('#composer-mode-hint')).toHaveText(/Comment — not sent to the agent/);
    await expect(page.getByRole('button', { name: 'Post comment', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Choose images', exact: true })).toHaveCount(0);
    await page.screenshot({ path: `tmp/thread-comment-mode-${width}.png` });
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

    // The same Enter that sends a prompt posts the comment, and nothing is
    // sent to the agent: no new turn appears, and the box returns to asking.
    await box.fill(text);
    await box.press('Enter');
    const comment = page.locator('.thread-comment', { hasText: `Reviewed at ${width}px` });
    await expect(comment).toBeVisible();
    await expect(comment.locator('strong', { hasText: 'looks right' })).toBeVisible();
    await expect(comment).toContainText('@commenter');
    // Inline, after the turn that was on screen when it was posted.
    await expect(reply.locator('.thread-comment', { hasText: `Reviewed at ${width}px` })).toHaveCount(1);
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toHaveValue('');
    await expect(page.locator('#transcript-turns > article')).toHaveCount(turns);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);

    await comment.getByRole('button', { name: 'Edit your comment', exact: true }).click();
    const edit = comment.getByRole('textbox', { name: 'Edit comment', exact: true });
    await expect(edit).toHaveValue(text);
    await edit.fill(`Edited at ${width}px`);
    await comment.getByRole('button', { name: 'Save', exact: true }).click();
    const edited = page.locator('.thread-comment', { hasText: `Edited at ${width}px` });
    await expect(edited.locator('.thread-comment-edited')).toHaveText('edited');
    await page.screenshot({ path: `tmp/thread-comment-${width}.png` });
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);

    page.once('dialog', dialog => dialog.accept());
    await edited.getByRole('button', { name: 'Delete your comment', exact: true }).click();
    await expect(page.locator('.thread-comment.deleted').last()).toContainText('Comment deleted');
    await expect(page.locator('body')).not.toContainText(`Edited at ${width}px`);
  }
});
