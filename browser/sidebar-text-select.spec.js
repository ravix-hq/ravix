import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// RAV-137: the rail is controls, not prose. A press and drag from its gutter
// across every row, the grab a person makes to move a project, selects no
// text; the same drag on a project's name still files it under a section;
// and a field inside the rail keeps its own text selectable.
test('dragging across the sidebar selects no text, still drags a project and leaves a field editable', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1280, height: 720 });
  await signIn(page, 'railselect', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const projectDialog = page.getByRole('dialog', { name: 'Add a repository' });
  await page.getByLabel('Project name', { exact: true }).fill('Rail select');
  await expect(page.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await page.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await projectDialog.getByRole('button', { name: 'Add repository' }).click();
  await expect(projectDialog).not.toBeVisible();
  const projectRow = page.locator('#yard .workspace-project.current');
  await projectRow.locator('.project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
  await expect(projectRow.locator('.project-tree-tracks .track-tab')).toHaveCount(1);

  // A section of this person's own, so the project's row is draggable, as
  // it is for anyone who has organized the rail.
  await page.getByRole('button', { name: 'Manage sections', exact: true }).click();
  await page.getByLabel('New section', { exact: true }).fill('Rail work');
  await page.getByRole('button', { name: 'Create section', exact: true }).click();
  const sectionsDialog = page.getByRole('dialog', { name: 'Project sections', exact: true });
  await expect(sectionsDialog.getByLabel('Section name', { exact: true })).toHaveValue('Rail work');
  await page.keyboard.press('Escape');
  await expect(sectionsDialog).toHaveCount(0);
  const sectionGroup = page.locator('.project-section').filter({ has: page.locator('.section-toggle', { hasText: 'Rail work' }) });
  await expect(sectionGroup).toBeVisible();
  await expect(projectRow).toHaveAttribute('draggable', 'true');

  // Press in the gutter beside the first row of the Projects area and drag
  // to the bottom corner of the rail, over the scope switch, the section
  // heading, the project and its track.
  const rail = page.locator('#yard');
  const scroll = page.locator('#yard .yard-scroll');
  const [railBox, scrollBox] = await Promise.all([rail.boundingBox(), scroll.boundingBox()]);
  await page.mouse.move(railBox.x + 3, scrollBox.y + 4);
  await page.mouse.down();
  for (let step = 1; step <= 12; step++) {
    await page.mouse.move(
      railBox.x + 3 + ((railBox.width - 24) * step) / 12,
      scrollBox.y + 4 + ((scrollBox.height - 12) * step) / 12,
    );
  }
  await page.mouse.up();
  // Evidence before any assertion, so the same steps photograph origin/main.
  await page.screenshot({ path: 'tmp/rav-137-rail-drag.png', clip: { x: 0, y: 0, width: 320, height: 720 } });
  expect(await page.evaluate(() => window.getSelection().toString())).toBe('');
  for (const selector of ['.yard-nav .yard-item', '#rail-scope button', '.section-toggle', '.workspace-project-name', '.track-tab']) {
    expect(await rail.locator(selector).first().evaluate(el => getComputedStyle(el).userSelect), selector).toBe('none');
  }

  // The same press, on the project's name, is a drag that files it.
  await projectRow.locator('.workspace-project-name .truncate').dragTo(sectionGroup.locator('.section-toggle'));
  await expect(sectionGroup.locator('.workspace-project-name')).toContainText('Rail select');
  await page.reload();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(sectionGroup.locator('.workspace-project-name')).toContainText('Rail select');

  // No field sits in the rail today; one placed there keeps its text
  // selectable, by the mouse and by the keyboard.
  await scroll.evaluate(el => {
    const input = document.createElement('input');
    input.id = 'rail-field-probe';
    input.setAttribute('aria-label', 'Rail field probe');
    input.value = 'rename me';
    el.prepend(input);
  });
  const field = page.locator('#rail-field-probe');
  expect(await field.evaluate(el => getComputedStyle(el).userSelect)).toBe('text');
  const fieldBox = await field.boundingBox();
  await page.mouse.move(fieldBox.x + 4, fieldBox.y + fieldBox.height / 2);
  await page.mouse.down();
  await page.mouse.move(fieldBox.x + fieldBox.width - 4, fieldBox.y + fieldBox.height / 2, { steps: 6 });
  await page.mouse.up();
  expect(await field.evaluate(el => el.value.slice(el.selectionStart, el.selectionEnd))).toBe('rename me');
  await field.press('End');
  await field.press('Shift+Home');
  expect(await field.evaluate(el => el.value.slice(el.selectionStart, el.selectionEnd))).toBe('rename me');
  await field.fill('renamed');
  await expect(field).toHaveValue('renamed');
});
