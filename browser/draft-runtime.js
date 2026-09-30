import { expect } from '@playwright/test';

// RAV-80: a draft thread's agent and model are the composer's pill, whose
// menu holds them as radios of the composer's form. These read and pick
// through it the way a person does: open the pill, click the choice.
export const draftPill = page => page.locator('#draft-runtime-trigger');
const menu = page => page.locator('#draft-runtime-menu');

export const draftChoice = (page, field) =>
  menu(page).locator(`input[name="thread_draft[${field}]"]:checked`);

export const draftModels = page =>
  menu(page).locator('input[name="thread_draft[model]"]').evaluateAll(nodes => nodes.map(n => n.value));

// The friendly name the menu shows for a model.
export const draftModelLabel = (page, model) =>
  menu(page).locator(`label:has(input[name="thread_draft[model]"][value="${model}"]) .truncate`).textContent();

// Choosing an agent keeps the menu open for its models, so it is closed
// here; choosing a model closes it.
export async function chooseDraft(page, field, value) {
  if (!(await menu(page).evaluate(el => el.matches(':popover-open')))) await draftPill(page).click();
  await expect(menu(page)).toBeVisible();
  await menu(page).locator(`label:has(input[name="thread_draft[${field}]"][value="${value}"])`).click();
  await expect(draftChoice(page, field)).toHaveValue(value);
  if (field === 'runtime') await page.keyboard.press('Escape');
  await expect(menu(page)).toBeHidden();
}

// "+" is a menu (RAV-97): New thread (with its shortcut hint) opens the draft.
export const newThread = async page => {
  await page.locator('#thread-add-trigger').click();
  await page.locator('#thread-add-menu').getByRole('button', { name: /^New thread/ }).click();
};
