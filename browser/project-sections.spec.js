import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';
import { openAddRepository } from './new-track.js';

// RAV-130: creating a section used to leave its name in the New section
// field, because the server rendered `value=""` before and after and so
// patched nothing; the next click made a duplicate, refused as a toast
// reading "name has already been taken". Now the field empties and keeps
// the focus, the new section is pointed out, and a taken name is a
// sentence under the field it was typed in, for creating and for renaming.
test('creating a section clears its field and a taken name is refused under the field', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1280, height: 800 });
  // Its own person, so the sections made here reach no other spec's Home.
  await signIn(page, 'sectionkeeper', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  const newProject = page.getByRole('dialog', { name: 'Add a repository' });
  await newProject.getByLabel('Project name', { exact: true }).fill('Kept project');
  await expect(newProject.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await newProject.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await newProject.getByRole('button', { name: 'Add repository', exact: true }).click();
  await expect(newProject).not.toBeVisible();

  await page.getByRole('button', { name: 'Manage sections', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Project sections', exact: true });
  const field = dialog.getByLabel('New section', { exact: true });
  const create = dialog.getByRole('button', { name: 'Create section', exact: true });
  await expect(field).toHaveAttribute('autocomplete', 'off');

  await field.fill('Ravioli');
  await create.click();
  const renames = dialog.getByLabel('Section name', { exact: true });
  await expect(renames).toHaveCount(1);
  await expect(renames).toHaveValue('Ravioli');
  await expect(renames).toHaveAttribute('autocomplete', 'off');
  // Emptied and refocused, ready for the next name; the new row is marked.
  await expect(field).toHaveValue('');
  await expect(field).toBeFocused();
  await expect(dialog.locator('.section-editor.created')).toHaveCount(1);

  // Typing the next name straight away works, and marks that row instead.
  await page.keyboard.type('Pasta');
  await page.keyboard.press('Enter');
  await expect(renames).toHaveCount(2);
  await expect(field).toHaveValue('');
  await expect(dialog.locator('.section-editor.created')).toHaveCount(1);
  await expect(dialog.locator('.section-editor.created').getByLabel('Section name', { exact: true })).toHaveValue('Pasta');

  // A taken name stays in the field with its sentence under it; no toast.
  await field.fill('Ravioli');
  await create.click();
  const error = dialog.locator('#new-section-form .error');
  await expect(error).toHaveText('You already have a section called Ravioli.');
  await expect(field).toHaveValue('Ravioli');
  await expect(renames).toHaveCount(2);
  await expect(page.locator('#flash-error')).toHaveCount(0);
  await expect(dialog.locator('.section-editor.created')).toHaveCount(0);

  // Renaming to a taken name is refused in that section's own form.
  // By id: the refusal re-renders the field's value, so a filter on it would lose the form.
  const pastaId = await dialog.locator('form[id^="rename-section-"]').filter({ has: page.locator('input[value="Pasta"]') }).getAttribute('id');
  const pasta = dialog.locator(`#${pastaId}`);
  await pasta.getByLabel('Section name', { exact: true }).fill('Ravioli');
  await pasta.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(pasta.locator('.error')).toHaveText('You already have a section called Ravioli.');
  await expect(pasta.getByLabel('Section name', { exact: true })).toHaveValue('Ravioli');
  await expect(dialog.locator('.error')).toHaveCount(2);
  await expect(page.locator('#flash-error')).toHaveCount(0);

  // A name that goes through clears the refusal.
  await pasta.getByLabel('Section name', { exact: true }).fill('Lasagne');
  await pasta.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(dialog.locator('.section-editor input[value="Lasagne"]')).toHaveCount(1);
  await expect(pasta.locator('.error')).toHaveCount(0);
  await expect(dialog.locator('.error')).toHaveCount(1);
});
