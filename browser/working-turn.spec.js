import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// RAV-91: a working turn, as four surfaces say it --- the shown thread's tab,
// the composer's Stop, the header's machine chip (which the dock's asleep
// state reads too) and the Checks pane's working note. Also the request
// progress bar and the typing line (RAV-91's other two parts). They are drawn from
// one `@turn` assign, so on every DOM change they must agree: Stop exactly
// while the tab says Running, and the chip's Working and the Checks note
// exactly while the tab says Running or Queued. `SCREENSHOT_DIR` keeps the
// review shots.
test.use({ viewport: { width: 1440, height: 900 } });

const shoot = async (page, name) => {
  if (process.env.SCREENSHOT_DIR) await page.screenshot({ path: `${process.env.SCREENSHOT_DIR}/${name}.png` });
};

test('the tab, Stop, the machine chip and Checks agree throughout a turn', async ({ page }) => {
  test.setTimeout(150_000);
  await signIn(page, 'workingturn');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Working turn');
  await project.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(project).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });

  const chip = page.locator('#track-machine-state');
  const tab = page.locator('#thread-tablist [role=tab][aria-selected=true]');
  const stop = page.locator('#composer-form').getByRole('button', { name: 'Stop agent', exact: true });
  await expect(chip).toHaveText('Idle', { timeout: 30_000 });
  await expect(tab).toBeVisible();

  // Request progress is a 2px bar along the page's top edge, transparent
  // for its first 400ms and never in the way of a click.
  await page.evaluate(() => window.liveSocket.enableLatencySim(900));
  await page.getByRole('navigation', { name: 'Inspector panels' }).getByRole('button', { name: 'Checks', exact: true }).click();
  const bar = page.locator('#request-progress');
  await expect(bar).toBeVisible();
  // Read off its animation rather than raced against the clock.
  expect(await bar.evaluate(el => {
    const fade = el.getAnimations().find(a => a.animationName === 'request-progress-in');
    return fade && { delay: fade.effect.getTiming().delay, from: fade.effect.getKeyframes()[0].opacity };
  })).toEqual({ delay: 400, from: '0' });
  await expect.poll(() => bar.evaluate(el => Number(getComputedStyle(el).opacity))).toBe(1);
  const box = await bar.boundingBox();
  expect(box).toMatchObject({ x: 0, y: 0, height: 2 });
  expect(await bar.evaluate(el => getComputedStyle(el).pointerEvents)).toBe('none');
  await expect(bar).toHaveText('Waiting for a response…');
  await shoot(page, 'request-progress');
  await expect(bar).toBeHidden();
  await page.evaluate(() => window.liveSocket.disableLatencySim());
  await expect(page.locator('#git-status')).toBeVisible();

  // Every DOM change from here on records what each surface says.
  await page.evaluate(() => {
    window.turnRecord = [];
    const read = () => {
      const label = document.querySelector('#thread-tablist [role=tab][aria-selected=true]')?.getAttribute('aria-label') ?? '';
      const [, word = 'Idle'] = label.match(/· (Running|Queued|Failed|Idle)\b/) ?? [];
      window.turnRecord.push({
        tab: word,
        stop: !!document.querySelector('#composer-stop'),
        chip: document.getElementById('track-machine-state')?.textContent.trim(),
        checks: !!document.getElementById('git-working'),
      });
    };
    new MutationObserver(read).observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    read();
  });

  // Your own typing is not announced to you, and the line it would take is
  // held either way, so the composer does not move.
  const notice = page.locator('#typing-notice');
  expect((await notice.boundingBox()).height).toBe(18);
  const composerTop = (await page.locator('#composer-form').boundingBox()).y;
  await composer.fill('Demonstrate a long-running turn');
  await composer.press('End');
  await page.keyboard.type(' now');
  await page.waitForFunction(() => window.turnRecord.length > 0);
  await expect(notice).toHaveText('');
  expect((await page.locator('#composer-form').boundingBox()).y).toBe(composerTop);
  await composer.press('Enter');

  await expect(stop).toBeVisible({ timeout: 30_000 });
  await expect(tab).toHaveAttribute('aria-label', /· Running/);
  await expect(chip).toHaveText('Working');
  await expect(page.locator('#git-working')).toBeVisible();
  await expect(notice).toHaveText('');
  await shoot(page, 'working');

  await stop.click();
  await expect(stop).toHaveCount(0, { timeout: 30_000 });
  await expect(tab).toHaveAttribute('aria-label', /· Idle/, { timeout: 30_000 });
  await expect(chip).toHaveText('Idle', { timeout: 30_000 });
  await expect(page.locator('#git-working')).toHaveCount(0);
  await shoot(page, 'stopped');

  const record = await page.evaluate(() => window.turnRecord);
  expect(record.some(r => r.tab === 'Running')).toBe(true);
  const disagreements = record.filter(r =>
    r.stop !== (r.tab === 'Running') ||
    (r.chip === 'Working') !== ['Running', 'Queued'].includes(r.tab) ||
    r.checks !== ['Running', 'Queued'].includes(r.tab));
  expect(disagreements).toEqual([]);
});
