import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn, connectClaude } from './sign-in.js';

// RAV-93: the transcript's type scale, code chips, links, lists, bubble,
// live turn, footer, focus, scroll edge and jump-to-latest. The numbers are
// the issue's targets, read as computed styles at 1440×900.
//
// `RAV93_SHOTS=<dir>` also writes the PR's screenshots there, at 1440 and
// 1280 wide, before any assertion runs.
const shots = process.env.RAV93_SHOTS;

test('the transcript reads at the issue\'s scale and its live turn, footer and edges behave', async ({ page, request }) => {
  test.setTimeout(180_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'dana');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const project = page.getByRole('dialog', { name: 'New project', exact: true });
  await project.getByLabel('Project name', { exact: true }).fill('Transcript polish');
  await project.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(project).toHaveCount(0);
  const projectId = new URL(page.url()).pathname.split('/')[2];
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('dialog', { name: 'New track', exact: true })
    .getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 45_000 });
  const mock = `http://localhost:${process.env.MOCK_PORT || 8893}`;
  const list = async path => {
    const response = await request.get(`${mock}/api/${path}`);
    expect(response.ok()).toBe(true);
    return (await response.json()).data;
  };
  const agent = (await list('agents')).find(agent => agent.metadata?.ravix?.project === projectId);
  const conversation = (await list('conversations')).find(conversation => conversation.agent_id === agent.id);
  const send = async prompt => {
    const submitted = await request.post(`${mock}/api/conversations/${conversation.id}/prompts`, { data: { prompt } });
    expect(submitted.ok()).toBe(true);
  };
  const scroller = page.locator('#transcript-scroll');
  const style = (locator, property, pseudo = null) =>
    locator.evaluate((el, [property, pseudo]) => getComputedStyle(el, pseudo).getPropertyValue(property), [property, pseudo]);
  const shoot = async name => {
    if (!shots) return;
    for (const width of [1440, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      await page.screenshot({
        path: `${shots}/${name}-${width}.png`,
        mask: [page.getByText(/[\w.+-]+@[\w-]+\.[\w.]+/)],
      });
    }
    await page.setViewportSize({ width: 1440, height: 900 });
  };

  const long = 'The scheduler puts some meetings on the wrong day twice a year. I think it is the day arithmetic, but I have not checked the window helper or the tests yet. Demonstrate a formatted answer';
  await send(long);
  const formatted = page.locator('.workspace-turn').filter({ hasText: 'Demonstrate a formatted answer' });
  await expect(formatted.locator('.turn-footer time')).toBeVisible({ timeout: 30_000 });
  await send('Thanks');
  const short = page.locator('.workspace-turn').filter({ has: page.locator('.workspace-prompt', { hasText: /^Thanks$/ }) });
  await expect(short.locator('.turn-footer time')).toBeVisible({ timeout: 30_000 });

  // A live turn: two interim messages, then 12 seconds of nothing new.
  await send('Demonstrate a turn thinking aloud');
  const live = page.locator('.workspace-turn').filter({ hasText: 'I will read the scheduler' });
  await expect(live.locator('.turn-running .turn-elapsed')).toBeVisible({ timeout: 30_000 });
  await expect(live).toContainText('so I am starting there');
  await shoot('live');
  if (shots) {
    await expect(live.locator('.turn-footer time')).toBeVisible({ timeout: 30_000 });
    const box = await scroller.boundingBox();
    await page.mouse.click(box.x + box.width - 30, box.y + box.height - 8);
    await shoot('transcript');
    // The edge under the tab strip, close up, with a paragraph scrolled
    // half under it.
    await formatted.locator('.agent-terminal-output .md p').first().evaluate(el => {
      const scroller = el.closest('#transcript-scroll');
      scroller.scrollTop += el.getBoundingClientRect().top - scroller.getBoundingClientRect().top + 12;
      scroller.dispatchEvent(new Event('scroll'));
    });
    const edge = await scroller.boundingBox();
    await page.screenshot({ path: `${shots}/edge-1440.png`, clip: { x: edge.x, y: edge.y - 44, width: 520, height: 110 } });
    await scroller.evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')); });
    await shoot('jump');
    return;
  }
  // Printed with one decimal, in the mono face, after a spinner.
  await expect(live.locator('.turn-running .turn-elapsed')).toHaveText(/^\d+\.\ds$/);
  expect(await style(live.locator('.turn-running .turn-elapsed'), 'font-family')).toMatch(/mono/i);
  await expect(live.locator('.turn-running .turn-spinner')).toBeVisible();
  const spinner = await live.locator('.turn-running .turn-spinner').boundingBox();
  const runningHeight = (await live.locator('.turn-running').boundingBox()).height;
  // The running turn's earlier message is muted while it runs; its latest
  // is not, and neither is anything once the turn has ended.
  const said = live.locator('.agent-terminal-output .md');
  const ink = await style(formatted.locator('.agent-terminal-output .md').first(), 'color');
  expect(await style(said.first(), 'color')).not.toBe(ink);
  expect(await style(said.last(), 'color')).toBe(ink);
  const axe = () => new AxeBuilder({ page }).include('#transcript-scroll')
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect((await axe()).violations).toEqual([]);
  await expect(live.locator('.turn-footer time')).toBeVisible({ timeout: 30_000 });
  expect(await style(said.first(), 'color')).toBe(ink);
  // Settling puts the copy icon where the spinner was, on a line as tall.
  const copy = await live.locator('.turn-footer .turn-copy').boundingBox();
  expect(Math.abs(copy.x + copy.width / 2 - (spinner.x + spinner.width / 2))).toBeLessThanOrEqual(0.5);
  expect((await live.locator('.turn-footer').boundingBox()).height).toBeCloseTo(runningHeight, 0);

  // Focus: clicking empty transcript space draws no ring, and typing then
  // lands in the composer.
  await scroller.evaluate(el => { el.scrollTop = el.scrollHeight; });
  const box = await scroller.boundingBox();
  await page.mouse.click(box.x + box.width - 30, box.y + box.height - 8);
  await expect(scroller).toBeFocused();
  expect(await style(scroller, 'outline-style')).toBe('none');
  await page.keyboard.type('hi');
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeFocused();
  await expect(composer).toHaveValue('hi');
  await composer.fill('');

  // 1. Type scale: 15/24 body, 12–16px between paragraphs.
  const body = formatted.locator('.agent-terminal-output .md p').first();
  expect(await style(body, 'font-size')).toBe('15px');
  expect(await style(body, 'line-height')).toBe('24px');
  const gap = parseFloat(await style(body, 'margin-bottom'));
  expect(gap).toBeGreaterThanOrEqual(12);
  expect(gap).toBeLessThanOrEqual(16);

  // 2. Inline code: a bordered chip lighter than the page, padded 2×5.
  const chip = body.locator('code').first();
  expect(await style(chip, 'padding')).toBe('2px 5px');
  expect(await style(chip, 'border-top-width')).toBe('1px');
  expect(await style(chip, 'border-top-style')).toBe('solid');
  // `color-mix()` computes to `color(srgb r g b)` in 0–1, a plain colour to
  // `rgb(r, g, b)` in 0–255.
  const luminance = color => {
    const scale = color.startsWith('color(') ? 255 : 1;
    return color.match(/[\d.]+/g).slice(0, 3).map(Number).reduce((a, b) => a + b * scale, 0);
  };
  const surface = await page.locator('body').evaluate(el => {
    const probe = document.createElement('span');
    probe.style.backgroundColor = 'var(--surface)';
    el.append(probe);
    const color = getComputedStyle(probe).backgroundColor;
    probe.remove();
    return color;
  });
  expect(luminance(await style(chip, 'background-color'))).toBeGreaterThan(luminance(surface));

  // 3. Links: the accent colour, a muted ↗ after an external one, and the
  // autolinker leaves a closing quote out of the URL.
  const accent = await page.locator('body').evaluate(el => {
    const probe = document.createElement('span');
    probe.style.color = 'var(--accent)';
    el.append(probe);
    const color = getComputedStyle(probe).color;
    probe.remove();
    return color;
  });
  const temporal = formatted.getByRole('link', { name: /Temporal proposal/ });
  expect(await style(temporal, 'color')).toBe(accent);
  expect(await style(temporal, 'content', '::after')).toContain('↗');
  await expect(formatted.locator('a[href="http://localhost:4000/"]')).toHaveCount(1);
  await expect(formatted.locator('a[href*="%22"], a[href$="\\""]')).toHaveCount(0);

  // 4. Lists: a muted marker and 6–8px between items.
  const item = formatted.locator('.md ul > li').nth(1);
  expect(await style(item, 'color', '::marker')).not.toBe(await style(item, 'color'));
  const itemGap = parseFloat(await style(item, 'margin-top'));
  expect(itemGap).toBeGreaterThanOrEqual(6);
  expect(itemGap).toBeLessThanOrEqual(8);

  // 5. The bubble fits what it holds, up to 80%, pinned right, radius 8.
  const longBubble = formatted.locator('.workspace-prompt');
  const shortBubble = short.locator('.workspace-prompt');
  const longWidth = (await longBubble.boundingBox()).width;
  const shortWidth = (await shortBubble.boundingBox()).width;
  expect(shortWidth).toBeLessThan(longWidth / 3);
  const column = await short.boundingBox();
  const shortBox = await shortBubble.boundingBox();
  expect(Math.abs(column.x + column.width - (shortBox.x + shortBox.width))).toBeLessThan(2);
  expect(longWidth).toBeLessThanOrEqual(column.width * 0.8 + 1);
  expect(await style(shortBubble, 'border-top-left-radius')).toBe('8px');

  // 7. Footer: a ⋯ menu with exactly the two copy items, and the copy icon
  // where it was on the running line.
  const footer = formatted.locator('.turn-footer');
  const more = footer.getByRole('button', { name: 'More for this turn', exact: true });
  await more.click();
  const menu = page.getByRole('menu', { name: 'More for this turn', exact: true });
  await expect(menu.getByRole('menuitem')).toHaveText(['Copy link to turn', 'Copy text']);
  await expect(menu.getByRole('menuitem').first()).toBeFocused();
  expect((await axe()).violations).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();

  // 9. The scroll edge under the tab strip fades once the transcript scrolls.
  await scroller.evaluate(el => { el.scrollTop = 200; });
  await expect(scroller).toHaveClass(/scrolled/);
  expect(await style(scroller, 'background-image', '::before')).toContain('gradient');

  // 10. Jump to latest sits about 12px above the composer.
  await scroller.evaluate(el => { el.scrollTop = 0; el.dispatchEvent(new Event('scroll')); });
  const jump = page.getByRole('button', { name: 'Jump to latest', exact: true });
  await expect(jump).toBeVisible();
  for (const width of [1440, 1280]) {
    await page.setViewportSize({ width, height: 900 });
    const composerTop = (await page.locator('#composer-form').boundingBox()).y;
    const pill = await jump.boundingBox();
    expect(Math.abs(composerTop - (pill.y + pill.height) - 12)).toBeLessThanOrEqual(4);
  }

  // The copied link opens this thread scrolled to its turn, not to the end.
  await page.setViewportSize({ width: 1440, height: 900 });
  const link = await formatted.locator('[data-copy-link]').getAttribute('data-copy-link');
  expect(link).toMatch(new RegExp(`^/p/${projectId}/t/[^?]+\\?thread=[^#]+#turns-`));
  await page.goto(link);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(formatted.locator('.workspace-prompt')).toBeInViewport();
  await expect(live.locator('.turn-footer')).not.toBeInViewport();
});
