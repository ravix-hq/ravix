import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn, connectClaude } from './sign-in.js';

// RAV-65: a row's status dot keeps its slot when there is none, so the
// avatars down the rail are one column whichever rows have a dot.
test('sidebar avatars line up whether or not a row shows a status dot', async ({ page }) => {
  test.setTimeout(120_000);
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill(`Aligned rail ${Date.now().toString(36)}`);
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  const projectPath = new URL(page.url()).pathname;
  const ids = [];
  for (let i = 0; i < 3; i++) {
    const previousPath = new URL(page.url()).pathname;
    await page.locator('#yard .workspace-project.current .project-add').click();
    await page.getByRole('button', { name: 'Create track', exact: true }).click();
    await expect.poll(() => new URL(page.url()).pathname).not.toBe(previousPath);
    // Idle is drawn once setup is ready and the opening turn has settled, so
    // nothing the server does later redraws a row's dot under the test.
    await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });
    ids.push(new URL(page.url()).pathname.split('/t/')[1]);
  }
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database) || ids.some(id => !/^[a-f0-9-]{36}$/.test(id))) throw new Error('Invalid browser fixture');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  const sql = query => execFileSync('psql', [`${server}/${database}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-c', query], { encoding: 'utf8' }).trim();
  // Fixture row only: the middle track's machine failed, which draws a dot.
  sql(`UPDATE ravix.tracks SET sandbox_state = 'failed' WHERE id = '${ids[1]}'`);

  await page.goto(projectPath);
  const rows = ids.map(id => page.locator(`#project-track-tab-${id}`));
  const dot = rows[1].locator('.track-status .dot.error');
  await expect(dot).toBeVisible();
  await expect(dot).toHaveAttribute('role', 'img');
  await expect(dot).toHaveAttribute('aria-label', 'Error');
  await expect(dot).toHaveAttribute('data-tip', "Error: This track's machine failed.");
  for (const index of [0, 2]) await expect(rows[index].locator('.dot')).toHaveCount(0);

  // Avatars are left out while one person made every track shown (RAV-96),
  // so the columns are the status slot, and the avatar when there is one.
  const x = async (row, selector) => (await row.locator(selector).boundingBox()).x;
  const avatars = await page.locator('#project-tree[data-one-creator]').count() === 0;
  for (const selector of ['.track-status', ...(avatars ? ['.track-creator'] : []), '.track-title']) {
    const xs = await Promise.all(rows.map(row => x(row, selector)));
    expect(new Set(xs).size, `${selector} x-positions ${xs}`).toBe(1);
  }
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});

// RAV-44/45: a chevron that follows each disclosure's state (mouse and
// keyboard), and a quiet empty section. RAV-96: a section's chevron and its
// projects' are one column; tracks step in from their project.
test('the sidebar tree steps in per level and its chevrons follow their state', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  // Its own person, so the sections made here reach no other spec's rail.
  await signIn(page, 'sidebartree', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const newProject = page.getByRole('dialog', { name: 'Add a repository' });
  await newProject.getByLabel('Project name', { exact: true }).fill('Tree filed');
  await expect(newProject.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await newProject.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await newProject.getByRole('button', { name: 'Add repository', exact: true }).click();
  await expect(newProject).not.toBeVisible();
  await page.locator('#yard .workspace-project.current .project-add').click();
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await newTrack.getByRole('button', { name: 'Options', exact: true }).click();
  await newTrack.getByLabel('Branch name').fill('tree-work');
  await newTrack.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(newTrack).not.toBeVisible();

  const manage = page.getByRole('button', { name: 'Manage sections', exact: true });
  await expect(manage).toHaveAttribute('data-tip', 'Organize projects into sections');
  const sections = page.getByRole('dialog', { name: 'Project sections', exact: true });
  await manage.click();
  for (const [index, name] of ['Filed', 'Empty shelf'].entries()) {
    await sections.getByLabel('New section', { exact: true }).fill(name);
    await sections.getByRole('button', { name: 'Create section', exact: true }).click();
    await expect(sections.getByLabel('Section name', { exact: true })).toHaveCount(index + 1);
  }
  await sections.getByRole('combobox', { name: 'Section for Tree filed', exact: true }).selectOption({ label: 'Filed' });
  await page.keyboard.press('Escape');

  const group = name => page.locator('.project-section').filter({ has: page.locator('.section-toggle', { hasText: name }) });
  const filed = group('Filed'), shelf = group('Empty shelf');
  const project = filed.locator('.workspace-project');
  const projectToggle = project.locator('.project-collapse');
  await expect(project.locator('.workspace-project-name')).toContainText('Tree filed');
  await expect(shelf.locator('.section-empty')).toHaveText('No projects');

  const x = locator => locator.evaluate(el => el.getBoundingClientRect().x);
  const turned = locator => locator.evaluate(el => getComputedStyle(el).transform !== 'none');
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: 900 });
    if (width < 760) {
      // RAV-104: the narrow rail is `display: none` until the server's answer
      // to Menu lands, and a box measured before then is all zeros. The
      // button's `aria-expanded` comes in the same render that opens it.
      const menu = page.getByRole('button', { name: 'Menu', exact: true });
      await menu.click();
      await expect(menu).toHaveAttribute('aria-expanded', 'true');
    }
    // Section and project chevrons in one column, then the track further in.
    const section = await x(filed.locator('.section-toggle svg'));
    const projectX = await x(projectToggle.locator('svg'));
    const track = await x(project.locator('.track-status').first());
    expect(Math.round(section)).toBe(Math.round(projectX));
    expect(projectX).toBeLessThan(track);
    // The empty line's words start where its projects' names would.
    expect(await shelf.locator('.section-empty').evaluate(el => el.getBoundingClientRect().x + parseFloat(getComputedStyle(el).paddingLeft))).toBeGreaterThan(projectX);
    // Every row stays on one line, and nothing scrolls sideways.
    for (const row of [filed.locator('.section-toggle'), project.locator('.workspace-project-row'), project.locator('.track-tab').first()]) {
      expect((await row.boundingBox()).height).toBeLessThan(36);
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);

    // A project's chevron: ⌄ open, › closed, by mouse and by keyboard.
    await expect(projectToggle).toHaveAttribute('aria-expanded', 'true');
    await expect.poll(() => turned(projectToggle.locator('svg'))).toBe(true);
    await projectToggle.click();
    await expect(projectToggle).toHaveAttribute('aria-expanded', 'false');
    await expect(project.locator('.track-tab')).toBeHidden();
    await expect.poll(() => turned(projectToggle.locator('svg'))).toBe(false);
    await projectToggle.focus();
    await page.keyboard.press('Enter');
    await expect(projectToggle).toHaveAttribute('aria-expanded', 'true');
    await expect(project.locator('.track-tab')).toBeVisible();
    await expect.poll(() => turned(projectToggle.locator('svg'))).toBe(true);
    await page.keyboard.press('Space');
    await expect(projectToggle).toHaveAttribute('aria-expanded', 'false');
    await page.keyboard.press('Enter');
    await expect(projectToggle).toHaveAttribute('aria-expanded', 'true');

    // A section's chevron the same way; collapsing it hides only its own.
    const sectionToggle = filed.locator('.section-toggle');
    await sectionToggle.click();
    await expect(sectionToggle).toHaveAttribute('aria-expanded', 'false');
    await expect(project).toBeHidden();
    await expect(shelf.locator('.section-empty')).toBeVisible();
    await expect.poll(() => turned(sectionToggle.locator('svg'))).toBe(false);
    await sectionToggle.focus();
    await page.keyboard.press('Enter');
    await expect(sectionToggle).toHaveAttribute('aria-expanded', 'true');
    await expect(project).toBeVisible();
    await expect.poll(() => turned(sectionToggle.locator('svg'))).toBe(true);
    expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
    if (width < 760) await page.getByRole('button', { name: 'Close menu', exact: true }).click();
  }
});
