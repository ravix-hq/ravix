import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-60: New track leads with its prompt and keeps the rest in chips, and
// the whole dialog fits a 1280×720 window: Create in view, nothing clipped,
// nothing to scroll. The chips' popovers open from the keyboard, close on
// Escape without closing the dialog, and give focus back to their chip.
// `SCREENSHOT_DIR` saves the review shots, `SCREENSHOT_PREFIX` names them.
test.use({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });

const shoot = async (page, n, slug) => {
  if (process.env.SCREENSHOT_DIR)
    await page.screenshot({ path: `${process.env.SCREENSHOT_DIR}/${process.env.SCREENSHOT_PREFIX || 'after'}-${n}-${slug}.png` });
};

async function axeClean(page) {
  const result = await new AxeBuilder({ page }).include('#new-track-dialog')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(result.violations).toEqual([]);
}

// Inside the window and inside the dialog, and not cut off by a scroller.
async function fullyShown(page, locator) {
  await expect(locator).toBeInViewport({ ratio: 1 });
  const box = await locator.boundingBox();
  const dialog = await page.locator('#new-track-dialog-dialog').boundingBox();
  expect(box.y).toBeGreaterThanOrEqual(dialog.y);
  expect(box.y + box.height).toBeLessThanOrEqual(dialog.y + dialog.height + 0.5);
}

test('New track fits 1280×720 with Create in view, and its chips are keyboard menus', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'newtrackfit', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Atlas API');
  await expect(page.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await project.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await project.getByRole('button', { name: 'Add repository', exact: true }).click();
  await expect(project).toHaveCount(0);

  const dialog = page.getByRole('dialog', { name: 'New track', exact: true });
  const prompt = dialog.getByRole('textbox', { name: 'What do you want to work on?', exact: true });
  const create = dialog.getByRole('button', { name: 'Create track', exact: true });
  const repo = dialog.locator('#new-track-repo-trigger');
  const model = dialog.locator('#new-track-model-trigger');

  // Ctrl+N (this is Linux) opens it from the page, focused on the prompt.
  await page.evaluate(() => document.activeElement?.blur());
  await page.keyboard.press('Control+n');
  await expect(dialog).toBeVisible();
  await expect(prompt).toBeFocused();
  await expect(prompt).toHaveAttribute('placeholder', 'What do you want to work on?');
  await expect(dialog).not.toContainText('Optional');
  await expect(dialog).not.toContainText('Project default:');
  await expect(repo).toContainText('mockuser/atlas-api');
  await expect(model).toBeEnabled();
  await expect(model).toContainText('Claude Code · ');
  await expect(create).toBeEnabled();
  await shoot(page, 1, 'open-1440x900');

  await page.setViewportSize({ width: 1280, height: 720 });
  for (const part of [prompt, repo, model, dialog.locator('#new-track-options'), create]) await fullyShown(page, part);
  // Nothing to scroll: the body holds all it has.
  expect(await page.locator('#new-track-dialog .dialog-body').evaluate(el => el.scrollHeight <= el.clientHeight)).toBe(true);
  await axeClean(page);
  await shoot(page, 2, 'open-1280x720');

  // The repository chip: ArrowDown opens it into the search, Escape closes
  // only the popover, and focus is back on the chip.
  await repo.focus();
  await page.keyboard.press('ArrowDown');
  const repoMenu = dialog.locator('#new-track-repo-menu');
  await expect(repoMenu).toBeVisible();
  await expect(repo).toHaveAttribute('aria-expanded', 'true');
  // Focus is in the popover: the search, or without workspaces the select.
  await expect(repoMenu.locator('#repo-picker-query, #new-track-project').first()).toBeFocused();
  await expect(repoMenu).toBeInViewport({ ratio: 1 });
  await axeClean(page);
  await shoot(page, 3, 'repository-popover');
  await page.keyboard.press('Escape');
  await expect(repoMenu).toBeHidden();
  await expect(dialog).toBeVisible();
  await expect(repo).toHaveAttribute('aria-expanded', 'false');
  await expect(repo).toBeFocused();

  // Sharing from the keyboard: Enter opens it on the current choice, an
  // arrow moves the choice without closing, Enter confirms.
  const sharing = dialog.locator('#new-track-sharing-trigger');
  await expect(sharing).toContainText('Everyone');
  await sharing.focus();
  await page.keyboard.press('Enter');
  const sharingMenu = dialog.locator('#new-track-sharing-menu');
  await expect(sharingMenu.locator('input[value=project]')).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(sharingMenu).toBeVisible();
  await expect(sharingMenu.locator('input[value=private]')).toBeChecked();
  await page.keyboard.press('Enter');
  await expect(sharingMenu).toBeHidden();
  await expect(sharing).toContainText('Only me');
  await expect(sharing).toBeFocused();
  await expect(dialog).toBeVisible();

  // The model chip opens the composer's menu above the footer; picking a
  // model closes it and the chip shows the choice.
  await model.click();
  const modelMenu = dialog.locator('#new-track-model-menu');
  await expect(modelMenu).toBeVisible();
  await expect(model).toHaveAttribute('aria-expanded', 'true');
  await expect(modelMenu).toBeInViewport({ ratio: 1 });
  await expect(modelMenu.locator('input[name="new_track[runtime]"]:checked')).toBeFocused();
  await axeClean(page);
  await shoot(page, 4, 'model-menu');
  const models = modelMenu.locator('fieldset', { hasText: 'Model' }).locator('label');
  const last = models.last();
  const name = (await last.locator('.truncate').textContent()).trim();
  await last.click();
  await expect(modelMenu).toBeHidden();
  await expect(model).toContainText(name);
  await expect(model).toBeFocused();

  // Options unfold in the body; the footer, and Create, stay where they are.
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();
  await expect(dialog.getByLabel('Branch name', { exact: true })).toBeVisible();
  await fullyShown(page, create);
  await axeClean(page);
  await shoot(page, 5, 'options-open');
  await dialog.getByRole('button', { name: 'Options', exact: true }).click();

  // Enter creates.
  await prompt.fill('Add a health check endpoint');
  await prompt.press('Enter');
  await expect(dialog).toHaveCount(0);
  await expect(page.locator('.workspace-queue')).toContainText('Add a health check endpoint');
  await expect(page.locator('.composer-model')).toContainText(name);
  await expect(page.locator('.track-crumbs')).toContainText('Private');
});
