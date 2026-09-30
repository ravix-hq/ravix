import { test, expect } from '@playwright/test';
import { newThread } from './draft-runtime.js';
import AxeBuilder from '@axe-core/playwright';
import { composerFixture } from './composer-fixture.js';
import { signIn as signInAs, connectClaude } from './sign-in.js';
import { openProjectSettings, saveMachine } from './settings.js';

async function primaryAppearance(locator) {
  return locator.evaluate((element) => {
    const style = getComputedStyle(element);
    return Object.fromEntries(['backgroundColor', 'color', 'borderColor', 'borderRadius',
      'padding', 'fontSize', 'fontWeight', 'lineHeight'].map((key) => [key, style[key]]));
  });
}

// Home's recent tracks (RAV-100): the title and the age line up row to row,
// and a long name wraps inside its row rather than pushing it wider.
async function recentColumns(page) {
  const rows = page.locator('.home-recent .recent-row');
  expect(await rows.count()).toBeGreaterThanOrEqual(2);
  const columns = await rows.evaluateAll((elements) => elements.map((row) => {
    const title = row.querySelector('.recent-main').getBoundingClientRect();
    const age = row.querySelector('.track-age').getBoundingClientRect();
    return { title: title.x, age: age.right, right: row.getBoundingClientRect().right, overflow: row.scrollWidth > row.clientWidth };
  }));
  for (const column of columns) {
    expect(column.title).toBeCloseTo(columns[0].title, 0);
    expect(column.age).toBeCloseTo(columns[0].age, 0);
    expect(column.right).toBeLessThanOrEqual(page.viewportSize().width);
    expect(column.overflow).toBe(false);
  }
}

// A track in the open project, from the sidebar's +, with the defaults.
// Its setup turn finishes while it is on screen, so it leaves nothing
// unread behind for the Inbox.
async function openTrackHere(page) {
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page).toHaveURL(url => url.pathname.includes('/t/'));
  await expect(page.locator('#track-setup-status')).toHaveCount(0, { timeout: 60_000 });
}

async function accessible(page) {
  // Settle first. Axe computes contrast against *composited* colour, so an
  // element measured while something fades is measured against a blend that
  // never appears on screen: opening a dialog runs `.scrim`'s 120ms fade, and
  // a check landing inside that window failed every element behind it at once,
  // against a background matching no declared theme.
  //
  // Only finite animations are waited for. The pulsing status dots and the
  // spinner run `infinite`, and their `finished` promise never resolves.
  await page.evaluate(() =>
    Promise.all(
      document
        .getAnimations()
        .filter((a) => a.effect?.getTiming?.().iterations !== Infinity)
        .map((a) => a.finished.catch(() => {})),
    ),
  );

  const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(result.violations).toEqual([]);
}

// The walkthrough test below signs in by hand, because walking it is what it
// is about. Everything else takes the shared helper, whose waits explain
// themselves in `sign-in.js`.
const signIn = (page) => signInAs(page, 'mockuser');

// In the workspace the picker is inside the account menu, which is opened
// first and shut again afterwards so that it covers nothing measured next.
async function openAccountMenu(page) {
  const menu = page.locator('#account-menu');
  if (!(await menu.evaluate(el => el.matches(':popover-open')))) await page.locator('#account-trigger').click();
  await expect(menu).toBeVisible();
  return menu;
}

async function chooseTheme(page, name) {
  const inMenu = (await page.locator('#account-trigger').count()) > 0;
  if (inMenu) await openAccountMenu(page);
  await page.locator('[data-theme-toggle]').click();
  await page.getByRole('menuitemradio', { name, exact: true }).click({ timeout: 15_000 });
  await expect(page.locator('html')).toHaveAttribute('data-theme', name.toLowerCase().replaceAll(' ', '-'));
  if (inMenu) {
    await page.keyboard.press('Escape');
    await expect(page.locator('#account-menu')).toBeHidden();
  }
  // Measure the selected palette after its CSS transitions, not a mixed frame.
  await page.evaluate(async () => {
    await new Promise(requestAnimationFrame);
    await Promise.all(document.getAnimations().filter(animation => animation instanceof CSSTransition).map(animation => animation.finished.catch(() => {})));
  });
}

// Record the palette on every frame, from before the page's own scripts run,
// so a frame painted in the wrong one is evidence afterwards rather than
// something only an eye on a hard reload catches.
function watchPalette(page, saved) {
  return page.addInitScript(`
    try { localStorage.setItem("ravix.theme", ${JSON.stringify(saved)}) } catch {}
    window.__palette = [];
    const sample = () => {
      const root = document.documentElement;
      if (root) {
        window.__palette.push({
          at: Math.round(performance.now()),
          theme: root.getAttribute("data-theme"),
          bg: getComputedStyle(root).getPropertyValue("--bg").trim(),
        });
      }
      requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  `);
}

async function paintedOnly(page, theme) {
  await page.evaluate(() => new Promise(requestAnimationFrame));
  const frames = await page.evaluate(() => window.__palette ?? []);
  expect(frames.length).toBeGreaterThan(0);
  expect(frames.filter((frame) => frame.theme !== theme)).toEqual([]);
}

async function fitsViewport(page) {
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
}

async function capture(page, name) {
  await fitsViewport(page);
  await page.screenshot({ path: test.info().outputPath(`${name}.png`), fullPage: true });
}

test('public design loads local Plex fonts and works in dark, light, and narrow layouts', async ({ page }) => {
  test.setTimeout(120_000);
  // The only public page. Pointing a signed-out browser at the root, or at a
  // workspace URL it cannot open, arrives at the same place.
  for (const path of ['/', '/inbox']) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/login$/);
    await expect(page).toHaveTitle('Sign in · Ravix');
  }
  await expect(page.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const fonts = await page.evaluate(async () => {
    const faces = [...document.fonts];
    await Promise.all(faces.map(face => face.load()));
    return faces.map(face => ({ family: face.family, status: face.status }));
  });
  expect(fonts).toHaveLength(8);
  expect(fonts.every(font => font.status === 'loaded' && font.family.startsWith('IBM Plex'))).toBe(true);
  expect(await page.evaluate(() => performance.getEntriesByType('resource').filter(entry => entry.name.includes('.woff2')).every(entry => new URL(entry.name).origin === location.origin))).toBe(true);
  for (const theme of ['Ravix', 'Daylight']) {
    await chooseTheme(page, theme);
    for (const width of [1280, 820, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await accessible(page);
      await capture(page, `login-${theme}-${width}`);
    }
  }
  // The chosen theme is the browser's, so it survives the redirect back here.
  await page.goto('/');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
});

// The account dialog test continues the walkthrough: it expects both agents
// the first visit connected. Serial keeps the two in one shard, in order.
test.describe.serial('first visit, then the account dialog', () => {
  test('a first visit is walked through how it works, the agent, and GitHub', async ({ page }) => {
    test.setTimeout(120_000);
    await page.goto('/');
    await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
    await page.getByRole('link', { name: 'Sign in as @mockuser', exact: true }).click();

    // Nobody chose to be here, so this is where a first visit lands.
    await expect(page).toHaveURL(/\/welcome$/);
    await expect(page).toHaveTitle('Welcome · Ravix');
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(page.getByRole('heading', { name: /^Welcome to Ravix/ })).toBeVisible();
    await expect(page.getByText('Describe a change. Ravix opens a branch, and your agent starts there.', { exact: true })).toBeVisible();
    await expect(page.getByText('You describe the task. Ravix opens a branch, and the agent starts there.', { exact: true })).toBeVisible();
    await page.locator('summary', { hasText: 'Review the work' }).click();
    await expect(page.getByText('The diff sits next to the conversation. The preview is the app, already running.', { exact: true })).toBeVisible();
    await page.locator('summary', { hasText: 'Bring someone into the same thread' }).click();
    await expect(page.getByText('Share the track. They continue the thread, with the earlier decisions still there.', { exact: true })).toBeVisible();
    await accessible(page);
    await capture(page, 'welcome-intro');

    await page.getByRole('link', { name: 'Set up your agent', exact: true }).click();
    await expect(page).toHaveURL(/\/welcome\/agent$/);
    await expect(page).toHaveTitle('Connect your agent · Ravix');
    // One decision: a card per agent, each offering Connect, and the rest
    // (API keys, replacing, removing) behind each card's ⋯ menu.
    await expect(page.getByRole('button', { name: 'Connect Claude Code', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Connect Codex', exact: true })).toBeVisible();
    await expect(page.locator('#agent-manage')).toBeHidden();
    await accessible(page);

    // Codex on a ChatGPT subscription is a sign-in, not a paste: the page shows
    // the code the mock Fountain hands out and notices the approval by itself
    // (the mock approves on the third poll). Nothing here is ever a token.
    await page.getByRole('button', { name: 'Connect Codex', exact: true }).click();
    await expect(page.getByLabel('API key', { exact: true })).toHaveCount(0);
    await accessible(page);
    await page.getByRole('button', { name: 'Connect ChatGPT', exact: true }).click();
    await expect(page.locator('#chatgpt-user-code')).toHaveText('MOCK-CODE');
    await expect(page.getByRole('link', { name: 'https://auth.openai.com/codex/device' })).toHaveAttribute('target', '_blank');
    await accessible(page);
    await capture(page, 'welcome-chatgpt');
    await expect(page.locator('#agent-codex-status')).toContainText('Connected', { timeout: 30_000 });
    await expect(page.locator('#agent-codex-status')).toContainText('Default for new projects');
    await expect(page.locator('#agent-later')).toHaveText('Continue');
    expect(await page.content()).not.toContain('MOCK-CODE');

    // Claude Code takes a pasted token.
    await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
    await expect(page.getByText('claude setup-token')).toBeVisible();
    await accessible(page);
    await capture(page, 'welcome-agent');

    // The mock refuses anything containing "invalid", the way Fountain refuses
    // a token its provider rejects. The refusal lands on the field and the value
    // is not given back.
    await page.getByLabel('Subscription token', { exact: true }).fill('sk-ant-oat01-invalid');
    await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
    await expect(page.getByText(/Anthropic did not accept that/)).toBeVisible();
    await expect(page.getByLabel('Subscription token', { exact: true })).toHaveValue('');
    await accessible(page);

    await page.getByLabel('Subscription token', { exact: true }).fill('sk-ant-oat01-mock');
    await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
    await expect(page.locator('#agent-claude-status')).toContainText('Connected');
    // Adding Claude leaves the first connected agent (Codex) as the default;
    // Claude's card offers to be it.
    await expect(page.locator('#agent-codex-status')).toContainText('Default for new projects');
    await page.locator('#agent-menu-claude-trigger').click();
    await expect(page.getByRole('menu', { name: 'Claude Code' })).toBeVisible();
    await accessible(page);
    await page.keyboard.press('Escape');
    await expect(page.getByRole('menu', { name: 'Claude Code' })).toBeHidden();
    await page.locator('#make-default-claude').click();
    await expect(page.locator('#agent-claude-status')).toContainText('Default for new projects');
    await page.getByRole('link', { name: 'Continue', exact: true }).click();
    await expect(page).toHaveURL(/\/welcome\/github$/);
    await page.goto('/welcome/github');
    await expect(page).toHaveTitle('Connect GitHub · Ravix');
    expect(await page.content()).not.toContain('sk-ant-oat01-mock');
    await expect(page.getByRole('heading', { name: 'Connect GitHub' })).toBeVisible();
    await expect(page.locator('#github-connected, #github-none')).toBeVisible();
    await accessible(page);
    await capture(page, 'welcome-github');

    // Coming back part way through carries on from here, not from the top.
    await page.goto('/');
    await expect(page).toHaveURL(/\/welcome\/github$/);
    await expect(page).toHaveTitle('Connect GitHub · Ravix');

    const continueStyle = await primaryAppearance(page.locator('#github-continue'));
    const continueHeight = (await page.locator('#github-continue').boundingBox()).height;
    await page.locator('#github-continue').click();
    await expect(page).toHaveURL(/\/welcome\/project$/);
    await expect(page).toHaveTitle('Start your first track · Ravix');
    await expect(page.getByRole('heading', { name: 'What do you want to work on?' })).toBeVisible();
    const start = page.getByRole('button', { name: 'Start', exact: true });
    expect(await primaryAppearance(start)).toEqual(continueStyle);
    expect((await start.boundingBox()).height).toBeCloseTo(continueHeight, 0);
    expect((await start.boundingBox()).width).toBeLessThan(
      (await page.locator('#first-prompt-form').boundingBox()).width / 2);
    await accessible(page);
    await page.setViewportSize({ width: 390, height: 844 });
    await accessible(page);
    await capture(page, 'welcome-project-mobile');

    // Leaving is finishing: the workspace stops sending this person back, and
    // the tests after this one start from an empty workspace as they always did.
    await page.getByRole('button', { name: 'Skip setup', exact: true }).click();
    await expect(page).toHaveURL(/\/home$/);
    await expect(page).toHaveTitle('Home · Ravix');
    await page.goto('/');
    await expect(page.getByRole('heading', { name: /Inbox/ })).toBeVisible();
  });

  test('Settings › Agents is where the agent lives after the walkthrough', async ({ page }) => {
    await signIn(page);
    const trigger = page.locator('#account-trigger');
    await trigger.click();
    const menu = page.locator('#account-menu');
    await expect(menu).toBeVisible();
    await accessible(page);
    await capture(page, 'account-menu');
    // Escape inside the palette list shuts the list and leaves the menu open;
    // the next Escape shuts the menu and puts focus back on its trigger.
    await menu.locator('[data-theme-toggle]').click();
    await expect(page.getByRole('menu', { name: 'Theme' })).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('menu', { name: 'Theme' })).toBeHidden();
    await expect(menu).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(menu).toBeHidden();
    await expect(trigger).toBeFocused();
    // A click outside shuts it too.
    await trigger.click();
    await page.locator('#workspace-stage').click({ position: { x: 400, y: 300 } });
    await expect(menu).toBeHidden();
    // Settings opens the person's own pages (RAV-77); the agent is Agents.
    await trigger.click();
    await menu.getByRole('button', { name: 'Settings', exact: true }).click();
    await expect(menu).toBeHidden();
    await expect(page).toHaveURL(/\/settings\/profile$/);
    await page.locator('#settings-nav-agents').click();
    await expect(page).toHaveURL(/\/settings\/agents$/);
    const agents = page.locator('#settings-agents');
    await expect(agents).toContainText('Each project uses its selected agent');

    await expect(page.getByRole('group', { name: 'Agents' })).toBeVisible();
    await accessible(page);
    await expect(page.locator('#agent-claude-status')).toContainText('Connected');
    await expect(page.locator('#agent-codex-status')).toContainText('Connected');
    await page.locator('#make-default-codex').click();
    await expect(page.locator('#agent-codex-status')).toContainText('Default for new projects');
    await page.locator('#make-default-claude').click();
    await expect(page.locator('#agent-claude-status')).toContainText('Default for new projects');
    // Removing is in the card's ⋯ menu, and asks in the page, not the browser.
    const more = page.locator('#agent-menu-claude-trigger');
    const remove = page.locator('#remove-claude-subscription');
    await expect(agents.locator('[data-confirm]')).toHaveCount(0);
    await more.click();
    await remove.click();
    const confirmation = page.getByRole('group', { name: 'Confirm agent removal' });
    await expect(confirmation).toBeVisible();
    await expect(page.locator('#confirm-agent-disconnect')).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(confirmation).toBeVisible();
    await accessible(page);
    await confirmation.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(confirmation).toHaveCount(0);
    await expect(more).toBeFocused();
    await capture(page, 'settings-agents');
  });
});

test('home quick start creates a scratch project and recent navigation survives theme changes', async ({ page }) => {
  // Its own person: the tracks made here would otherwise be in every other
  // test's rail and Inbox.
  await signInAs(page, 'homerecent');
  await connectClaude(page);
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  await expect(page.getByRole('button', { name: /Open a local project/ })).toHaveCount(0);
  await accessible(page);
  await capture(page, 'home-empty');
  // With no project yet, /home is the first-prompt form (first-run.spec.js);
  // adding a repository is the sidebar's "Add repository" (RAV-100, RAV-37).
  await expect(page.locator('#home-start')).toBeVisible();
  await expect(page.locator('#home').getByRole('button', { name: /New project|Add a repository/ })).toHaveCount(0);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('Quick start quality');
  // Scratch is the list's last choice, and chosen while nothing else is.
  await expect(page.getByRole('radio', { name: 'No repository (scratch machine)', exact: true })).toBeChecked();
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(page.locator('#crumb-plans')).toBeVisible();
  await expect(page.locator('.crumbs')).toContainText('Quick start quality');
  await capture(page, 'project-empty');
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  const recent = page.getByRole('region', { name: 'Recent tracks' });
  await expect(recent).toContainText('No open tracks yet');
  await page.locator('#yard .workspace-project', { hasText: 'Quick start quality' })
    .getByRole('link', { name: /Quick start quality/ }).first().click();
  await openTrackHere(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('A much longer project name to verify columns and narrow screen wrapping');
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(page.locator('#crumb-plans')).toBeVisible();
  await openTrackHere(page);
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  await expect(recent.getByRole('link')).toHaveCount(2);
  await expect(recent).toContainText('Quick start quality');
  await expect(recent).toContainText('@homerecent');
  await recentColumns(page);
  for (const theme of ['Ravix', 'Daylight']) {
    await chooseTheme(page, theme);
    await accessible(page);
    await capture(page, `home-${theme}`);
  }
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
  // Opening each track reads its setup reply, so the Inbox below is empty.
  await recent.getByRole('link', { name: /in A much longer project name/ }).click();
  await expect(page).toHaveURL(/\/p\/.+\/t\//);
  await expect(page.locator('.track-crumbs')).toBeVisible();
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  await recent.getByRole('link', { name: /in Quick start quality/ }).click();
  await expect(page).toHaveURL(/\/p\/.+\/t\//);
  await expect(page.locator('.track-crumbs')).toBeVisible();
  // Exact: an empty inbox must not put a "0" badge in the link's name.
  await page.getByRole('link', { name: 'Inbox', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: "You're all caught up" })).toBeVisible();
  await accessible(page);
  await capture(page, 'inbox-Daylight');
  await page.setViewportSize({ width: 390, height: 844 });
  const mobileNav = page.getByRole('navigation', { name: 'Workspace navigation' });
  await mobileNav.getByRole('link', { name: 'Home' }).click();
  await accessible(page);
  await recentColumns(page);
  await capture(page, 'home-mobile');
  // The rail is gone at this width, and everything in it --- signing out,
  // the theme picker, the account --- was unreachable until Menu brought it
  // back over the page. Following a link in it closes it again.
  const menu = mobileNav.getByRole('button', { name: 'Menu' });
  const account = page.locator('#account-trigger');
  await expect(account).toBeHidden();
  await expect(menu).toHaveAttribute('aria-expanded', 'false');
  await menu.click();
  await expect(menu).toHaveAttribute('aria-expanded', 'true');
  await expect(account).toBeVisible();
  await expect(page.getByRole('button', { name: 'Close menu' })).toBeVisible();
  await accessible(page);
  await capture(page, 'home-mobile-menu');
  await account.click();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
  await accessible(page);
  await capture(page, 'home-mobile-account-menu');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeHidden();
  await page.keyboard.press('Escape');
  await expect(account).toBeHidden();
  await menu.click();
  await page.getByRole('complementary', { name: 'Projects' }).getByRole('link', { name: 'Inbox' }).click();
  await expect(page.getByRole('heading', { name: "You're all caught up" })).toBeVisible();
  await expect(account).toBeHidden();
  await expect(menu).toHaveAttribute('aria-expanded', 'false');
});

test('workspace titles follow links, reloads and browser history', async ({ page }) => {
  await signIn(page);
  for (const name of ['Home', 'Inbox', 'Schedules']) {
    await page.getByRole('link', { name, exact: true }).first().click();
    await expect(page).toHaveTitle(`${name} · Ravix`);
    await page.reload();
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(page).toHaveTitle(`${name} · Ravix`);
  }
  await expect(page.getByRole('button', { name: 'Refresh', exact: true })).toHaveAccessibleDescription(
    'Refresh to see the latest run status and changes made in another tab.');
  await page.goBack();
  await expect(page).toHaveTitle('Inbox · Ravix');
  await expect(page.getByRole('button', { name: 'Refresh', exact: true })).toHaveCount(0);
});

test('mobile navigation marks the current page and names Search consistently', async ({ page }) => {
  await signIn(page);
  await page.setViewportSize({ width: 500, height: 844 });
  await page.goto('/home');
  const nav = page.getByRole('navigation', { name: 'Workspace navigation', exact: true });
  await expect(nav.getByRole('link', { name: 'Home', exact: true })).toHaveAttribute('aria-current', 'page');
  await expect(nav.locator('[aria-current="page"]')).toHaveCount(1);
  const gaps = await nav.evaluate(el => {
    const boxes = Array.from(el.children, child => child.getBoundingClientRect());
    return boxes.slice(1).flatMap((box, i) =>
      Math.abs(box.top - boxes[i].top) < 1 ? [box.left - boxes[i].right] : []);
  });
  expect(gaps.length).toBeGreaterThan(1);
  expect(Math.max(...gaps) - Math.min(...gaps)).toBeLessThan(1);
  await capture(page, 'mobile-nav-home-500');
  await nav.getByRole('link', { name: 'Inbox', exact: true }).click();
  await expect(nav.getByRole('link', { name: 'Inbox', exact: true })).toHaveAttribute('aria-current', 'page');
  await expect(nav.locator('[aria-current="page"]')).toHaveCount(1);
  await capture(page, 'mobile-nav-inbox-500');
  await nav.getByRole('button', { name: 'Search', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Search', exact: true })).toBeVisible();
  await expect(page.getByLabel('Search projects, tracks and plans')).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(nav.getByRole('button', { name: 'Search', exact: true })).toBeFocused();
  await nav.getByRole('button', { name: 'Menu', exact: true }).click();
  await expect(page.locator('#yard').getByRole('button', { name: 'Search', exact: true })).toBeVisible();
});

test('find a track focuses its search field and explains no matches', async ({ page }) => {
  await signIn(page);
  const open = page.getByRole('button', { name: 'Search', exact: true });
  const dialog = page.getByRole('dialog', { name: 'Search', exact: true });
  const query = dialog.getByLabel('Search projects, tracks and plans');

  await open.focus();
  await open.press('Enter');
  await expect(query).toBeFocused();
  await page.keyboard.type('no-track-could-match-this-query');
  await expect(dialog.getByRole('status')).toHaveText("No tracks match 'no-track-could-match-this-query'");
  await expect(dialog.locator('a')).toHaveCount(0);
  await expect(query).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(open).toBeFocused();

  await open.click();
  await expect(query).toBeFocused();
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await expect(open).toBeFocused();
});

test('keyboard users can resize panels and close dialogs with focus restored', async ({ page }) => {
  await signIn(page);
  const handle = page.getByRole('separator', { name: 'Sidebar width' });
  await handle.focus();
  await handle.press('Home');
  await expect(handle).toHaveAttribute('aria-valuenow', '220');
  await handle.press('ArrowRight');
  await expect(handle).toHaveAttribute('aria-valuenow', '230');
  const open = page.getByRole('complementary', { name: 'Projects' }).getByRole('button', { name: 'Add a repository', exact: true }).first();
  await open.focus();
  await open.press('Enter');
  const dialog = page.getByRole('dialog', { name: 'Add a repository' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('searchbox', { name: 'Repository', exact: true })).toBeFocused();
  await accessible(page);
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();
  await expect(open).toBeFocused();
});

test('project, track, streaming, image upload, reconnect, and revocation', async ({ page, context }) => {
  // Several streamed replies plus the navigation/reconnect checks.
  test.setTimeout(120_000);
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await signIn(page);
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const projectDialog = page.getByRole('dialog', { name: 'Add a repository' });
  await expect(projectDialog).toBeVisible();
  await page.getByLabel('Project name', { exact: true }).fill('Browser quality');
  await expect(page.locator('#project-repositories input[type=radio]')).not.toHaveCount(0);
  await page.getByRole('radio', { name: 'mockuser/atlas-api', exact: true }).check();
  await projectDialog.getByRole('button', { name: 'Add repository' }).click();
  await expect(projectDialog).not.toBeVisible();
  await page.locator('#yard .workspace-project.current .project-add').click();
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await expect(newTrack.getByLabel('Branch name')).toHaveValue('');
  await newTrack.getByRole('button', { name: 'Options', exact: true }).click();
  await expect(newTrack.getByRole('button', { name: 'Branch', exact: true })).toBeVisible();
  for (const [kind, value, label] of [
    ['Branch', 'release/2026-08', 'release/2026-08'],
    ['Pull request', '41', '#41 Count days in the local zone, not in 86400-second blocks'],
    ['Issue', '40', '#40 Timestamps drift by an hour after the clocks change'],
  ]) {
    await newTrack.getByRole('button', { name: kind, exact: true }).click();
    const refs = newTrack.getByLabel('Start from', { exact: true });
    await expect(refs.locator(`option[value="${value}"]`)).toHaveText(label);
    await expect(refs).toBeEnabled();
    await refs.selectOption(value);
    if (kind === 'Branch') {
      for (const width of [390, 1280]) {
        await page.setViewportSize({ width, height: 844 });
        const toggle = await newTrack.getByRole('textbox', { name: 'What do you want to work on?', exact: true }).boundingBox();
        const source = await newTrack.locator('.origin-options').boundingBox();
        const start = await refs.boundingBox();
        const branch = await newTrack.getByLabel('Branch name', { exact: true }).boundingBox();
        const row = await newTrack.locator('.track-branch-input').boundingBox();
        expect(toggle.y + toggle.height).toBeLessThanOrEqual(source.y);
        expect(source.y + source.height).toBeLessThanOrEqual(start.y);
        expect(start.y + start.height).toBeLessThan(branch.y);
        expect(branch.width).toBeGreaterThan(row.width * 0.7);
        expect(Math.abs(branch.x + branch.width - row.x - row.width)).toBeLessThan(2);
      }
      await page.setViewportSize({ width: 1280, height: 720 });
    }
    await expect(newTrack).toBeVisible();
    await expect(newTrack.getByRole('button', { name: 'Create track', exact: true })).toBeEnabled();
  }
  await newTrack.getByRole('button', { name: 'Options', exact: true }).click();
  await expect(newTrack.getByRole('button', { name: 'Branch', exact: true })).not.toBeVisible();
  await capture(page, 'new-track');
  await expect(newTrack.getByLabel('Branch name')).not.toBeVisible();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  const selectedTrackTitle = await page.locator('.project-tree-tracks [aria-current="page"] .track-title').textContent();
  await expect(page).toHaveTitle(`${selectedTrackTitle} · Browser quality · Ravix`);
  // The composer enables once the conversation exists, before the opening
  // turn has made the worktree. A diff read then is honestly empty and the
  // panel does not poll, so wait for the turn to settle first.
  await expect(page.locator('#transcript-status')).toHaveText('Agent replied', { timeout: 30_000 });
  await page.getByRole('button', { name: 'Changes', exact: true }).click();
  await expect(page.locator('.change-file')).toHaveCount(2);
  await page.getByLabel('Filter paths').fill('window');
  await expect(page.locator('.change-file')).toHaveCount(1);
  await page.locator('.change-file').press('Enter');
  await expect(page.getByRole('region', { name: 'Diff for src/lib/window.ts' })).toBeVisible();
  await expect(page.locator('.diff-line.diff-add')).not.toHaveCount(0);
  await accessible(page);
  await capture(page, 'changes-diff');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('navigation', { name: 'Track views' }).getByRole('button', { name: 'Files', exact: true }).click();
  await expect(page.locator('.file-diff')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await capture(page, 'changes-diff-mobile');
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.getByRole('button', { name: '← All changed files' }).click();
  await expect(page.getByLabel('Filter paths')).toHaveValue('window');
  await page.getByRole('button', { name: 'Files', exact: true }).click();
  const explorer = page.locator('.file-explorer');
  const src = explorer.getByRole('button', { name: 'src', exact: true });
  await expect(src).toHaveAttribute('aria-expanded', 'false');
  await src.press('Enter');
  await expect(src).toHaveAttribute('aria-expanded', 'true');
  await expect(explorer.locator('.file-list .file-list')).toBeVisible();
  const readme = explorer.getByRole('button', { name: 'README.md', exact: true });
  await expect(readme).toBeVisible();
  await readme.click();
  await expect(readme).toHaveAttribute('aria-current', 'true');
  await expect(explorer.locator('pre')).toContainText('A service that does one thing');
  await src.click();
  await expect(src).toHaveAttribute('aria-expanded', 'false');
  await expect(explorer.locator('.file-list .file-list')).toHaveCount(0);
  await expect(explorer.locator('pre')).toBeVisible();


  await accessible(page);
  await expect(page.locator('.crumbs')).toHaveCount(1);
  const firstTrackTab = page.locator('.project-tree-tracks .workspace-track[aria-current="page"]');
  await expect(firstTrackTab).toBeVisible();
  const firstTrackName = (await firstTrackTab.locator('.track-title').textContent()).trim();
  // RAV-48: the first prompt retitles the track, so find it again by id.
  const firstTrackTabId = await firstTrackTab.getAttribute('id');
  await expect(page.locator('#yard .project-tree-tracks .workspace-track')).toHaveCount(1);
  // Personal sections persist across reloads and never delete the projects inside.
  await page.getByRole('button', { name: 'Manage sections', exact: true }).click();
  await page.getByLabel('New section', { exact: true }).fill('Browser work');
  await page.getByRole('button', { name: 'Create section', exact: true }).click();
  const sectionsDialog = page.getByRole('dialog', { name: 'Project sections', exact: true });
  await expect(sectionsDialog.getByLabel('Section name', { exact: true })).toHaveValue('Browser work');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('combobox', { name: 'Section for Browser quality', exact: true })).toHaveCount(0);
  const sectionGroup = page.locator('.project-section').filter({ has: page.locator('.section-toggle', { hasText: 'Browser work' }) });
  await page.locator('#project-tree .workspace-project', { hasText: 'Browser quality' }).dragTo(sectionGroup);
  await expect(sectionGroup.locator('.workspace-project-name')).toContainText('Browser quality');
  await sectionGroup.locator('.section-toggle').click();
  await expect(sectionGroup.locator('.workspace-project-name')).toBeHidden();
  await page.reload();
  await expect(sectionGroup.locator('.section-toggle')).toHaveAttribute('aria-expanded', 'false');
  await sectionGroup.locator('.section-toggle').click();
  await expect(sectionGroup.locator('.workspace-project-name')).toBeVisible();
  await accessible(page);
  await capture(page, 'project-sections');
  await page.getByRole('button', { name: 'Manage sections', exact: true }).click();
  await sectionsDialog.getByLabel('Section name', { exact: true }).fill('Renamed work');
  await sectionsDialog.getByRole('button', { name: 'Rename', exact: true }).click();
  await expect(sectionsDialog.getByLabel('Section name', { exact: true })).toHaveValue('Renamed work');
  await sectionsDialog.getByRole('button', { name: 'Remove section', exact: true }).click();
  await expect(sectionsDialog.getByLabel('Section name', { exact: true })).toHaveCount(0);
  await page.keyboard.press('Escape');
  await expect(page.locator('#section-other .workspace-project-name', { hasText: 'Browser quality' })).toBeVisible();


  await page.keyboard.press('Escape');

  await expect(page.getByLabel('Command', { exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Commands', exact: true }).click();
  await expect(page.locator('#track-terminal .dock-empty')).toContainText('For an interactive shell, open a terminal with +.');
  await expect(page.locator('#track-terminal').getByRole('button', { name: 'Run', exact: true })).toHaveCount(0);
  await page.getByLabel('Command', { exact: true }).fill('echo draft');
  await page.getByRole('button', { name: 'Collapse the dock' }).click();
  await expect(page.getByLabel('Command', { exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Expand the dock' }).click();
  await expect(page.getByLabel('Command', { exact: true })).toHaveValue('echo draft');
  await page.getByRole('button', { name: 'Machine stats', exact: true }).click();
  await expect(page.getByLabel('Command', { exact: true })).not.toBeVisible();
  const stats = page.locator('.machine-stats');
  await expect(stats).toContainText('15%');
  await expect(stats).toContainText('1.0 GB of 8.0 GB');
  await expect(stats).toContainText('3.2 GB of 20.0 GB');
  await expect(stats.locator('meter')).toHaveCount(3);
  await expect(stats.getByRole('meter', { name: 'CPU in use', exact: true })).toHaveAttribute('value', '0.15');
  await accessible(page);
  await capture(page, 'machine-stats');
  await page.getByRole('button', { name: 'Commands', exact: true }).click();
  await expect(page.getByLabel('Command', { exact: true })).toHaveValue('echo draft');
  await page.getByRole('button', { name: 'Collapse the dock' }).click();
  await composer.fill('A draft while opening workspace dialogs');
  const newTrackTrigger = page.locator('#yard .workspace-project.current .project-add');
  await newTrackTrigger.click();
  await expect(newTrack).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(newTrackTrigger).toBeFocused();
  await expect(composer).toHaveValue('A draft while opening workspace dialogs');
  // Settings are a page in the shell (RAV-72): the track is left, and
  // Back returns to it.
  const trackPage = page.url();
  const settings = await openProjectSettings(page, 'danger');
  const removeProject = settings.getByRole('button', { name: 'Delete project', exact: true });
  await removeProject.scrollIntoViewIfNeeded();
  await expect(removeProject).toBeInViewport();
  await expect(page.locator('#yard')).toBeVisible();
  await capture(page, 'settings');
  await page.goBack();
  await page.goBack();
  await expect(page).toHaveURL(trackPage);
  await composer.fill('Explain this project for the browser smoke test');
  await composer.press('Enter');
  // A second prompt while the first one still holds the track: that one has to
  // wait behind it, so the saved-prompts panel is certain to be drawn rather
  // than racing a machine that took the prompt immediately. Both rows sit in
  // the panel, so the row is named by its own text and not by the panel alone.
  await composer.fill('Explain the queued project for the browser smoke test');
  await composer.press('Enter');
  const queued = page.locator('.workspace-queue > li')
    .filter({ hasText: 'Explain the queued project for the browser smoke test' });
  await expect(queued).toHaveCount(1);
  // The status chip is what makes this the queue rather than the transcript.
  await expect(queued.locator('.queue-state')).toHaveCount(1);
  // The prompt's own bubble, not just the page: the mock's reply quotes the
  // prompt back, so the transcript contains these words even when the prompt
  // never arrived. It reaches the live page on the turn's opening event, which
  // the follower reads back from the feed because the stream never carries it.
  // Saving wakes the queue worker, so this does not wait on its backstop timer.
  await expect(page.locator('#transcript-turns .said .workspace-prompt').filter({ hasText: 'Explain this project for the browser smoke test' })).toHaveCount(1, { timeout: 20_000 });
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Explain this project for the browser smoke test' }).locator('.agent-terminal-output > div > .md')).toContainText('There is one TODO worth doing here');
  // The agent's checklist, as it last stood: one plan, both lines, the first done.
  await expect(page.locator('.workspace-plan')).toHaveCount(1);
  await expect(page.locator('.workspace-plan li.plan-completed')).toContainText('Look for open TODOs');
  await expect(composer).toHaveValue('');
  // Interrupt the actual LiveSocket connection, preserving the browser's draft.
  await composer.fill('Draft survives reconnect');
  await page.evaluate(() => new Promise(resolve => window.liveSocket.disconnect(resolve)));
  await expect.poll(() => page.evaluate(() => window.liveSocket.getSocket().isConnected())).toBe(false);
  await page.evaluate(() => window.liveSocket.connect());
  await expect.poll(() => page.evaluate(() => window.liveSocket.getSocket().isConnected())).toBe(true);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(composer).toHaveValue('Draft survives reconnect');
  // "+" opens a draft thread: a tab and a blank composer, with no thread made
  // yet and the track's branch, URL and default draft left as they were.
  const trackUrl = page.url();
  // A new track is titled with its branch, which the header then shows once.
  const branch = (await page.locator('.project-tree-tracks [aria-current="page"] .track-title').textContent()).trim();
  await expect(page.locator('.track-crumbs')).toContainText(branch);
  const threadTabs = page.getByRole('navigation', { name: 'Threads', exact: true });
  const currentThread = threadTabs.locator('[aria-selected="true"]');
  const threadTab = id => threadTabs.locator(`button[data-thread-id="${id}"]`);
  const defaultThread = await currentThread.getAttribute('data-thread-id');
  const threadCount = await threadTabs.locator('.thread-tab').count();
  await newThread(page);
  await expect(currentThread).toHaveAttribute('data-thread-id', 'draft');
  await expect(page.locator('#draft-thread-empty')).toContainText('Your first message starts this thread.');
  await expect(composer).toHaveValue('');
  await expect(page.locator('.track-crumbs')).toContainText(branch);
  expect(page.url()).toBe(trackUrl);
  await composer.fill('A separate thread draft');
  await threadTab(defaultThread).click();
  await expect(composer).toHaveValue('Draft survives reconnect');
  // The tabs use manual activation: focus followed by Enter switches.
  await threadTab('draft').focus();
  await page.keyboard.press('Enter');
  await expect(threadTab('draft')).toHaveAttribute('aria-selected', 'true');
  await expect(composer).toHaveValue('A separate thread draft');
  await threadTab(defaultThread).click();
  await expect(composer).toHaveValue('Draft survives reconnect');
  // Discarding the draft made nothing: the tabs are the ones there were.
  await threadTabs.getByRole('button', { name: 'Discard new thread', exact: true }).click();
  await expect(threadTab('draft')).toHaveCount(0);
  await expect(threadTabs.locator('.thread-tab')).toHaveCount(threadCount);
  const chooserOpened = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose images', exact: true }).click();
  const chooser = await chooserOpened;
  await chooser.setFiles({
    name: 'pixel.png', mimeType: 'image/png',
    buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4WQAAAAASUVORK5CYII=', 'base64'),
  });
  // Attaching starts the transfer before Send, so progress cannot sit at 0%
  // while the person waits for the screenshot to be ready.
  await expect(page.locator('.workspace-upload')).toContainText('pixel.png (100%)');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.locator('.workspace-upload')).toHaveCount(0);
  // Reconnecting can leave the queue worker with no followed heads; the save
  // itself wakes it, so this waits only on the streamed reply.
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Draft survives reconnect' }).locator('.agent-terminal-output > div > .md')).toContainText('There is one TODO worth doing here', { timeout: 20_000 });
  await capture(page, 'track-Ravix');
  await chooseTheme(page, 'Daylight');
  await accessible(page);
  await capture(page, 'track-Daylight');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('navigation', { name: 'Track views' }).getByRole('button', { name: 'Conversation', exact: true }).click();
  await accessible(page);
  await capture(page, 'track-mobile');
  // On a phone the project's own controls live in the yard, and the yard is
  // behind Menu. The owner's "Project settings" is the one worth proving
  // reachable from the current project row.
  const trackMenu = page.getByRole('navigation', { name: 'Workspace navigation' }).getByRole('button', { name: 'Menu' });
  await expect(page.locator('#yard .workspace-project.current button[title="Project settings"]')).toBeHidden();
  await trackMenu.click();
  await expect(page.locator('#yard .workspace-project.current button[title="Project settings"]')).toBeVisible();
  await expect(page.locator('#account-trigger')).toBeVisible();
  await accessible(page);
  await capture(page, 'track-mobile-menu');
  await page.getByRole('button', { name: 'Close menu' }).click();
  await expect(page.locator('#yard .workspace-project.current button[title="Project settings"]')).toBeHidden();
  await page.setViewportSize({ width: 1280, height: 720 });
  // The same session is revoked from a second tab while the first remains connected.
  const trackURL = page.url();
  await composer.fill("This must never be sent");
  const other = await context.newPage();
  await other.goto('/home');
  await other.locator('#account-trigger').click();
  await other.getByRole('link', { name: 'Sign out' }).click();
  await expect(other.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
  // Submitting on a revoked session is refused by sending this browser to
  // sign in, and that navigation destroys the context this call is evaluated
  // in --- which Playwright reports as an error rather than a result, often
  // enough to fail a run. The refusal is what the assertions below read; the
  // call's own return value was never wanted. Any other error still fails.
  await page
    .evaluate(() => document.querySelector("#composer-form")?.requestSubmit())
    .catch((error) => {
      if (!/Execution context was destroyed/.test(error.message)) throw error;
    });
  await expect(page.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
  await signIn(page);
  await page.goto(trackURL);
  await expect(page.locator("#transcript-turns")).toBeVisible();
  await expect(page.locator("#transcript-turns")).not.toContainText("This must never be sent");
  // Two tracks, and moving between them. The page on the right is now one
  // LiveView handed from track to track rather than one torn down and rebuilt
  // for each, so everything a switch has to clear --- the transcript, the
  // crumbs, the scroll hook's idea of where it is --- is only correct because
  // it is cleared deliberately. A rebuild used to do all of that by accident.
  //
  // Last, and after the revocation above rather than before it: this section
  // is minutes of agent work, and the guard that section turns on holds its
  // answer for fifteen seconds, so anything inserted ahead of it moves what
  // that test is actually measuring.
  const firstLane = await page.locator('#transcript-scroll').getAttribute('data-track');
  await page.locator('#yard .workspace-project.current .project-add').click();
  await expect(newTrack).toBeVisible();
  await newTrack.getByRole('button', { name: 'Options', exact: true }).click();
  await page.getByLabel('Branch name').fill('second-lane');
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText('Second lane');
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#transcript-scroll')).not.toHaveAttribute('data-track', firstLane);
  // The track arrived at is its own; the one left behind had three turns in it.
  await expect(page.locator('#transcript-turns')).not.toContainText('Draft survives reconnect');
  await accessible(page);

  const firstTrackLink = page.locator(`#${firstTrackTabId}`);
  await expect(firstTrackLink.locator('.track-title')).not.toHaveText(firstTrackName);
  const firstTrackTitle = (await firstTrackLink.locator('.track-title').textContent()).trim();
  await firstTrackLink.click();
  await expect(page.locator('.track-crumbs')).toContainText(firstTrackTitle);
  await expect(page.locator('#transcript-scroll')).toHaveAttribute('data-track', firstLane);
  await expect(page.locator('#transcript-turns')).toContainText('Draft survives reconnect');

  await page.screenshot({ path: test.info().outputPath("workspace.png"), fullPage: true });
  expect(errors).toEqual([]);
});

test('a hard load paints the saved palette, never the default one first', async ({ page }) => {
  // The palette bootstrap is a blocking script in `<head>`, ahead of the
  // stylesheet, so the first paint is already in the reader's theme. It was
  // served as a 404 in production for a reason only a digested build can
  // show: `mix phx.digest` renames a file at the root, `Plug.Static` matches
  // `:only` against the request's first segment exactly, and the digested
  // name is not in that list. Dev and test never rewrite the tag, so the
  // page there asks for `/theme.js`, which is served. Every hard load in
  // production painted the default theme until LiveView connected — about a
  // fifth of a second on the signed-out page, which is the one a stranger
  // sees first.
  await watchPalette(page, 'hot-dog-stand');

  await page.goto('/login');
  const bootstrap = await page.locator('head script[src*="theme"]').getAttribute('src');
  expect((await page.request.get(bootstrap)).status()).toBe(200);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await paintedOnly(page, 'hot-dog-stand');

  // And again on a page behind the session, which is a second render of the
  // same layout and the one somebody reloads all day.
  await signIn(page);
  await page.goto('/');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await paintedOnly(page, 'hot-dog-stand');
});

test('help explains desktop connections and stays accessible on mobile', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await signIn(page);
  const account = page.locator('#account-trigger');
  const help = page.getByRole('button', { name: 'Help', exact: true });
  await account.click();
  await help.click();
  const dialog = page.getByRole('dialog', { name: 'Help – AI tools' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText(`claude mcp add --transport http ravix http://localhost:${process.env.BROWSER_PORT || 4103}/mcp`, { exact: true })).toBeVisible();
  await dialog.getByText('Drive tracks with an A2A client', { exact: true }).click();
  await expect(dialog.getByText(`http://localhost:${process.env.BROWSER_PORT || 4103}/.well-known/agent-card.json`, { exact: true })).toBeVisible();
  await dialog.getByText('Example JSON-RPC request', { exact: true }).click();
  await expect(dialog.locator('pre').filter({ hasText: 'SendMessage' })).toBeVisible();
  for (const id of ['help-mcp-command', 'help-a2a-request']) {
    const block = dialog.locator(`#${id}`);
    const expected = await block.locator('code').textContent();
    await block.getByRole('button', { name: /^Copy / }).click();
    await expect(block.getByRole('status')).toHaveText('Copied');
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(expected);
  }
  await accessible(page);
  await capture(page, 'tooling-help');
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  // Help was in the account menu, which shut as the dialog opened; focus
  // comes back to the menu's trigger rather than to a hidden item.
  await expect(account).toBeFocused();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('navigation', { name: 'Workspace navigation' }).getByRole('button', { name: 'Menu' }).click();
  await account.click();
  await help.click();
  await expect(dialog).toBeVisible();
  await dialog.getByText('Permissions, progress and disconnecting', { exact: true }).click();
  await expect(dialog.getByRole('link', { name: 'Connected applications' })).toHaveAttribute('href', '/settings/connected-apps');
  await accessible(page);
  await capture(page, 'tooling-help-mobile');
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await expect(dialog).toHaveCount(0);
});

test('project settings navigate, warn before discarding, and save sections accessibly', async ({ page }) => {
  await signIn(page);
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const create = page.getByRole('dialog', { name: 'Add a repository' });
  await create.getByLabel('Project name', { exact: true }).fill('Settings browser');
  await create.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(create).not.toBeVisible();
  const settings = await openProjectSettings(page);
  const nav = page.getByRole('navigation', { name: 'Settings sections' });
  const leave = page.getByRole('alertdialog', { name: 'Leave without saving?' });
  await expect(page).toHaveTitle('General · Settings browser · Ravix');
  await expect(page.getByRole('navigation', { name: 'Breadcrumb' })).toContainText('Settings browser');
  // One Save a page, in the unsaved-changes bar (RAV-74).
  const bar = page.getByRole('region', { name: 'Unsaved changes' });
  await settings.getByLabel('Name', { exact: true }).fill('Unsaved name');
  await expect(bar).toBeVisible();
  const nativeDialogs = [];
  page.on('dialog', async dialog => { nativeDialogs.push(dialog.type()); await dialog.dismiss(); });
  // Leaving a page with changes on it asks, in the page, never natively.
  await settings.locator('#settings-nav-agent').click();
  await expect(leave).toBeVisible();
  await expect(leave.getByRole('button', { name: 'Keep editing', exact: true })).toBeFocused();
  await accessible(page);
  await page.keyboard.press('Escape');
  await expect(leave).toBeHidden();
  await expect(page).toHaveURL(/\/settings\/general$/);
  await expect(settings.getByLabel('Name', { exact: true })).toHaveValue('Unsaved name');
  await bar.getByRole('button', { name: 'Discard', exact: true }).click();
  await expect(bar).toBeHidden();
  await expect(settings.getByLabel('Name', { exact: true })).toHaveValue('Settings browser');
  // The repository is shown, with a way to it.
  await expect(settings.locator('#general-repository')).toBeVisible();
  await settings.locator('#settings-nav-agent').click();
  await expect(leave).toBeHidden();
  await expect(page).toHaveURL(/\/settings\/agent$/);
  await expect(page.locator('#settings-title')).toHaveText('Agent');
  await expect(settings.locator('.agent-choice strong')).toHaveText(['Claude Code', 'Codex']);
  await settings.locator('#settings-agent-codex').click();
  await expect(settings.getByLabel('Model', { exact: true }).locator('option')).toHaveText(['GPT-6 Astra', 'GPT-5.5']);
  await settings.locator('#settings-agent-claude').click();
  await expect(settings.getByLabel('Model', { exact: true }).locator('option')).toHaveText(['Claude Opus 5.5', 'Claude Opus 5', 'Claude Sonnet 5']);
  await settings.getByLabel('Instructions', { exact: true }).fill('Explain changes and run focused tests.');
  await bar.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page.getByText('Settings saved.', { exact: true })).toBeVisible();
  await expect(bar).toBeHidden();
  await accessible(page);
  // Back and forward move between pages.
  await page.goBack();
  await expect(page).toHaveURL(/\/settings\/general$/);
  await page.goForward();
  await expect(page).toHaveURL(/\/settings\/agent$/);
  await settings.locator('#settings-nav-general').click();
  await expect(settings.getByLabel('Name', { exact: true })).toHaveValue('Settings browser');
  await settings.getByLabel('Name', { exact: true }).fill('Settings organized');
  await bar.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(bar).toBeHidden();
  // The Machine page: one Save & rebuild, which asks first. A run script
  // alone needs no rebuild, and a refusal lands on its field.
  await settings.locator('#settings-nav-machine').click();
  await settings.getByLabel('Run command', { exact: true }).fill('npm run dev -- --port "$PORT" --strictPort');
  await settings.getByLabel('Readiness path (optional)', { exact: true }).fill('health');
  await expect(bar.getByRole('button', { name: 'Save & rebuild', exact: true })).toBeVisible();
  await bar.getByRole('button', { name: 'Save & rebuild', exact: true }).click();
  const review = page.getByRole('alertdialog', { name: 'Save these changes?' });
  await expect(review).toContainText('run script edited');
  await expect(review.getByRole('button', { name: 'Save', exact: true })).toBeFocused();
  await accessible(page);
  await review.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(settings.locator('.field p.error')).toContainText('Readiness must be an HTTP path');
  await expect(page.getByText(/Could not save the run script/)).toBeVisible();
  await settings.getByLabel('Readiness path (optional)', { exact: true }).fill('/health');
  await saveMachine(page, ['run script edited']);
  // Each page opens at its top, wherever the last one was scrolled to.
  const body = settings.locator('.settings-body');
  let top;
  for (const section of ['access', 'machine', 'danger']) {
    await settings.locator(`#settings-nav-${section}`).click();
    await expect(page).toHaveURL(new RegExp(`/settings/${section}$`));
    await expect.poll(() => settings.evaluate(el => el.scrollTop)).toBe(0);
    top ??= (await body.boundingBox()).y;
    expect((await body.boundingBox()).y).toBeCloseTo(top, 0);
    await accessible(page);
  }
  await expect(nav.locator('.settings-group').last()).toHaveClass(/danger/);
  const rebuild = settings.getByRole('button', { name: 'Rebuild machine', exact: true });
  const remove = settings.getByRole('button', { name: 'Delete project', exact: true });
  await expect(rebuild).toBeDisabled();
  await expect(remove).toBeDisabled();
  await settings.getByLabel('Type Settings organized to confirm rebuilding', { exact: true }).fill('Settings organized');
  await expect(rebuild).toBeEnabled();
  await expect(remove).toBeDisabled();
  await settings.getByLabel('Type Settings organized to confirm rebuilding', { exact: true }).fill('wrong');
  await expect(rebuild).toBeDisabled();
  await settings.getByLabel('Type Settings organized to confirm deletion', { exact: true }).fill('Settings organized');
  await expect(remove).toBeEnabled();
  await expect(rebuild).toBeDisabled();
  await settings.getByLabel('Type Settings organized to confirm deletion', { exact: true }).fill('');
  await expect(remove).toBeDisabled();
  // A typed confirmation is not a change to save: leaving does not ask.
  await page.setViewportSize({ width: 390, height: 844 });
  await settings.locator('#settings-nav-agent').click();
  await expect(leave).toBeHidden();
  await expect(settings.getByLabel('Instructions', { exact: true })).toHaveValue('Explain changes and run focused tests.');
  await accessible(page);
  await capture(page, 'settings-mobile');
  let mobileTop;
  for (const section of ['general', 'access', 'machine', 'danger', 'agent']) {
    await settings.locator(`#settings-nav-${section}`).click();
    await expect(page).toHaveURL(new RegExp(`/settings/${section}$`));
    await expect.poll(() => settings.evaluate(el => el.scrollTop)).toBe(0);
    mobileTop ??= (await body.boundingBox()).y;
    expect((await body.boundingBox()).y).toBeCloseTo(mobileTop, 0);
    await fitsViewport(page);
  }
  const tabTops = await nav.locator('.settings-link').evaluateAll(tabs => tabs.map(tab => tab.getBoundingClientRect().top));
  expect(Math.max(...tabTops) - Math.min(...tabTops)).toBeLessThan(2);
  expect(nativeDialogs).toEqual([]);
});

test('composer Send stays compact and keeps its arrow after repeated submissions in every theme', async ({ page, request }) => {
  // Two streamed replies and the five-state theme/viewport matrix.
  test.setTimeout(150_000);
  await signIn(page);
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const projectDialog = page.getByRole('dialog', { name: 'Add a repository', exact: true });
  await projectDialog.getByLabel('Project name', { exact: true }).fill('Send regression');
  await projectDialog.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await expect(projectDialog).toHaveCount(0);
  await page.locator('#yard .workspace-project.current .project-add').click();
  // New tracks are named after their reserved ravix/ branch (#154).
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await newTrack.getByRole('button', { name: 'Options', exact: true }).click();
  await newTrack.getByLabel('Branch name', { exact: true }).fill('compact-send');
  await newTrack.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText('Compact send');
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  const send = page.getByRole('button', { name: 'Send', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  const checkSend = async () => {
    await expect(send).toBeVisible();
    const box = await send.boundingBox();
    expect(box.width).toBeLessThanOrEqual(80);
    expect(box.height).toBeLessThanOrEqual(44);
    // RAV-94 made every control in the row 28px, still above WCAG 2.5.8's
    // 24px target.
    expect(box.width).toBeGreaterThanOrEqual(28);
    expect(box.height).toBeGreaterThanOrEqual(28);
    await expect(send).toHaveText('');
    await expect(send).toHaveAttribute('title', 'Send');
    const svg = send.locator('svg');
    await expect(svg).toBeVisible();
    await expect(svg).toHaveAttribute('viewBox', '0 0 24 24');
    await expect(svg.locator('path')).toHaveAttribute('d', 'M12 19V5M6 11l6-6 6 6');
    expect(await svg.evaluate(el => el.namespaceURI)).toBe('http://www.w3.org/2000/svg');
    const colors = await send.evaluate(el => {
      const style = getComputedStyle(el);
      return { ink: style.color, background: style.backgroundColor, opacity: Number(style.opacity), stroke: getComputedStyle(el.querySelector('svg')).stroke };
    });
    expect(colors.ink).not.toBe(colors.background);
    expect(colors.stroke).toBe(colors.ink);
    expect(colors.opacity).toBeGreaterThanOrEqual(0.6);
    await expect(page.getByRole('button', { name: 'Choose images', exact: true }).locator('svg')).toBeVisible();
    await expect(page.locator('#composer-form')).not.toContainText('to send');
    const model = page.locator('.composer-model');
    await expect(model).toHaveText(/^\S/);
    expect(await model.getAttribute('title')).toMatch(/^(Claude Code|Codex) · /);
    await expect(model).toHaveAccessibleName(await model.locator('.truncate').innerText());
    expect(await model.evaluate(el => getComputedStyle(el).fontFamily)).toContain('IBM Plex Sans');
    await fitsViewport(page);
  };
  // The same checks for the 220-cell theme/viewport matrix, read in one
  // round trip per cell: the button is already settled there, so auto-waiting
  // locators only cost time. `checkSend` still runs once per status.
  const matrixSend = async () => {
    const m = await page.evaluate(() => {
      const send = document.querySelector('#composer-form button[aria-label="Send"]');
      const svg = send?.querySelector('svg');
      const path = svg?.querySelector('path');
      const images = document.querySelector('#composer-form [aria-label="Choose images"] svg');
      const model = document.querySelector('.composer-model');
      const visible = el => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
      const box = send?.getBoundingClientRect();
      const style = send && getComputedStyle(send);
      return {
        visible: visible(send), width: box?.width, height: box?.height,
        text: send?.textContent.trim(), title: send?.getAttribute('title'),
        svgVisible: visible(svg), viewBox: svg?.getAttribute('viewBox'), d: path?.getAttribute('d'),
        namespace: svg?.namespaceURI,
        ink: style?.color, background: style?.backgroundColor, opacity: Number(style?.opacity),
        stroke: svg && getComputedStyle(svg).stroke,
        imagesVisible: visible(images),
        formText: document.querySelector('#composer-form').textContent,
        modelText: model?.textContent.trim(), modelTitle: model?.getAttribute('title'),
        modelFont: model && getComputedStyle(model).fontFamily,
        fits: document.documentElement.scrollWidth <= window.innerWidth,
      };
    });
    expect(m.visible).toBe(true);
    expect(m.width).toBeLessThanOrEqual(80);
    expect(m.height).toBeLessThanOrEqual(44);
    expect(m.width).toBeGreaterThanOrEqual(28);
    expect(m.height).toBeGreaterThanOrEqual(28);
    expect(m.text).toBe('');
    expect(m.title).toBe('Send');
    expect(m.svgVisible).toBe(true);
    expect(m.viewBox).toBe('0 0 24 24');
    expect(m.d).toBe('M12 19V5M6 11l6-6 6 6');
    expect(m.namespace).toBe('http://www.w3.org/2000/svg');
    expect(m.ink).not.toBe(m.background);
    expect(m.stroke).toBe(m.ink);
    expect(m.opacity).toBeGreaterThanOrEqual(0.6);
    expect(m.imagesVisible).toBe(true);
    expect(m.formText).not.toContain('to send');
    expect(m.modelText).toMatch(/^\S/);
    expect(m.modelTitle).toMatch(/^(Claude Code|Codex) · /);
    expect(m.modelFont).toContain('IBM Plex Sans');
    expect(m.fits).toBe(true);
  };
  await chooseTheme(page, 'Bubblegum');
  // Sending previously destroyed the SVG. Exercise both mouse and Enter, and
  // inspect during the LiveView acknowledgement window as well as afterwards.
  let completedAnswers = await page.locator('#transcript-turns .turn-footer').count();
  for (const method of ['click', 'Enter']) {
    await page.evaluate(() => window.liveSocket.enableLatencySim(200));
    await composer.fill(`Send regression ${method}`);
    if (method === 'click') await send.click();
    else await composer.press('Enter');
    await expect(page.locator('#composer-form')).toHaveClass(/phx-submit-loading/);
    // One snapshot of the acknowledgement window, since RAV-87 lets send
    // leave the slot as soon as the box clears and the turn starts: while the
    // submit is out, send is there and still carries its arrow.
    const inFlight = await page.evaluate(() => {
      const form = document.querySelector('#composer-form');
      const path = form.querySelector('button[aria-label="Send"] svg path');
      return { loading: form.classList.contains('phx-submit-loading'), d: path?.getAttribute('d') };
    });
    if (inFlight.loading) expect(inFlight.d).toBe('M12 19V5M6 11l6-6 6 6');
    await expect(composer).toHaveValue('');
    // RAV-87: an empty box has nothing to send, so send is disabled or, while
    // the turn runs, stands aside for Stop. Typing brings it back, enabled.
    await composer.fill('Not sent');
    await expect(send).toBeEnabled();
    await checkSend();
    await composer.fill('');
    await page.evaluate(() => window.liveSocket.disableLatencySim());
    // Acknowledgement clears the input before the agent finishes. Keep this
    // button-rendering regression sequential instead of queuing another turn.
    await expect(page.locator('#transcript-turns .turn-footer')).toHaveCount(++completedAnswers, { timeout: 20_000 });
    await expect(page.locator('#composer-form').getByRole('button', { name: 'Stop agent', exact: true })).toHaveCount(0, { timeout: 30_000 });
  }
  await page.evaluate(() => window.liveSocket.disableLatencySim());
  await expect(page.locator('#transcript-turns')).toContainText('Send regression Enter', { timeout: 20_000 });
  await expect(page.locator('#composer-form').getByRole('button', { name: 'Stop agent', exact: true })).toHaveCount(0, { timeout: 30_000 });
  const fixture = composerFixture(new URL(page.url()).pathname.split('/').pop());
  const palettes = await page.locator('[data-theme-choice]').evaluateAll(els => [...new Set(els.map(el => el.dataset.themeChoice))]);
  expect(palettes).toHaveLength(22);
  for (const [status, connected] of [['opening', false], ['opening', true], ['running', true], ['ready', true], ['failed', true]]) {
    await fixture.state(request, status, connected);
    // An opening page reads the conversation memo (`MachineCache`, five
    // seconds), and nothing tells it the fixture moved the conversation. This
    // step used to pass only because the previous one outlasted the memo, so
    // reload until the page shows the new status instead of relying on that.
    await expect(async () => {
      await page.reload();
      await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
      await expect(page.locator('#composer-form').getByRole('button', { name: 'Stop agent', exact: true })).toHaveCount(status === 'running' ? 1 : 0, { timeout: 1_000 });
      await expect(page.locator('#composer-form').getByRole('button', { name: 'Wake / retry', exact: true })).toHaveCount(['opening', 'failed'].includes(status) ? 1 : 0, { timeout: 1_000 });
    }).toPass({ timeout: 15_000 });
    // RAV-87: Stop is drawn from the thread's tab, which says Running only
    // while a turn runs, not while the track is opening. With nothing typed,
    // send is disabled, or stands aside for Stop mid-turn; something to send
    // brings it back, so the matrix below still measures it. Setting the box
    // through `input` is how the hook hears it, disabled or not.
    const typeIn = value => composer.evaluate((el, value) => {
      el.value = value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }, value);
    await typeIn('');
    if (status === 'running') await expect(send).toBeHidden();
    else await expect(send).toBeDisabled();
    await typeIn('Queued while the agent works');
    await expect(send).toBeVisible();
    if (connected) await expect(send).toBeEnabled();
    else await expect(send).toBeDisabled();
    await checkSend();
    for (const theme of palettes) {
      // The picker is hidden behind Menu on phones; set its public palette
      // attribute directly so the matrix measures the same CSS in both sizes.
      await page.locator('html').evaluate((el, theme) => el.dataset.theme = theme, theme);
      for (const width of [1280, 390]) {
        await page.setViewportSize({ width, height: 900 });
        await page.evaluate(async () => {
          await new Promise(requestAnimationFrame);
          await Promise.all(document.getAnimations().filter(a => a instanceof CSSTransition).map(a => a.finished.catch(() => {})));
        });
        await test.step(`${status}, connected=${connected}, ${theme}, ${width}px`, matrixSend);
        if (theme === 'bubblegum') await page.screenshot({ path: test.info().outputPath(`send-${status}-${connected}-${width}.png`), fullPage: true });
      }
    }
  }
});

test('shared project prefixes stay muted and truncate across every theme', async ({ page, browser }) => {
  test.setTimeout(120_000);
  await signIn(page);
  await connectClaude(page);
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  const name = 'Shared project with a deliberately long name for a narrow rail';
  await page.getByLabel('Project name', { exact: true }).fill(name);
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  // An owner's project page links to its plans (RAV-8), not the track picker.
  await expect(page.locator('#crumb-plans')).toBeVisible();
  const projectPath = new URL(page.url()).pathname;
  await expect(page.locator('.workspace-project-name.selected .project-label')).toHaveText(name);
  await expect(page.locator('.workspace-project-name.selected .project-label .dim')).toHaveCount(0);
  // The owner's People is the project's Access settings page (RAV-74).
  await page.locator('#workspace-stage').getByRole('link', { name: 'People', exact: true }).click();
  await expect(page).toHaveURL(/\/settings\/access$/);
  await page.getByLabel('GitHub username', { exact: true }).fill('eli');
  await page.getByRole('button', { name: 'Invite', exact: true }).click();
  await expect(page.locator('#project-access')).toContainText('@eli');
  const people = page.locator('#project-access');
  const heights = await people.locator('.people-row').evaluateAll(rows =>
    rows.map(row => row.getBoundingClientRect().height));
  expect(heights.length).toBeGreaterThanOrEqual(2);
  expect(Math.max(...heights) - Math.min(...heights)).toBeLessThan(1);
  await expect(people.getByRole('button', { name: 'Revoke invite link', exact: true })).toHaveCount(0);
  await people.getByRole('button', { name: 'Create invite link', exact: true }).click();
  await expect(people.getByRole('button', { name: 'Replace invite link', exact: true })).toBeVisible();
  await people.getByRole('button', { name: 'Revoke invite link', exact: true }).click();
  await expect(people.getByRole('button', { name: 'Revoke invite link', exact: true })).toHaveCount(0);
  await accessible(page);
  await capture(page, 'people-even-rows');


  const memberContext = await browser.newContext({ baseURL: new URL(page.url()).origin });
  try {
    const member = await memberContext.newPage();
    await member.goto('/login');
    await member.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
    await member.getByRole('link', { name: 'Sign in as @eli', exact: true }).click();
    await member.goto(projectPath);
    await expect(member.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    const label = member.locator('.workspace-project-name.selected .project-label');
    await expect(label).toHaveText(`mockuser / ${name}`);
    await expect(member).toHaveTitle(`mockuser / ${name} · Ravix`);
    const railWidth = member.getByRole('separator', { name: 'Sidebar width' });
    await railWidth.focus();
    await railWidth.press('Home');
    // The menu supplies every supported theme's display name.
    const names = await member.getByRole('menuitemradio', { includeHidden: true }).evaluateAll(nodes => nodes.map(node => node.getAttribute('data-theme-name')));
    expect(names.length).toBeGreaterThan(2);
    for (const theme of names) {
      await chooseTheme(member, theme);
      const measured = await label.evaluate(node => {
        const prefix = node.querySelector('.dim');
        const style = getComputedStyle(node);
        const probe = document.createElement('span');
        probe.style.color = 'var(--dim)';
        node.append(probe);
        const dim = getComputedStyle(probe).color;
        probe.remove();
        return {
          prefix: getComputedStyle(prefix).color,
          dim,
          ellipsis: style.textOverflow,
          clipped: node.scrollWidth > node.clientWidth,
          fits: node.getBoundingClientRect().right <= node.closest('.workspace-project-name').getBoundingClientRect().right,
        };
      });
      expect(measured).toMatchObject({ prefix: measured.dim, ellipsis: 'ellipsis', clipped: true, fits: true });
    }
    for (const theme of ['Ravix', 'Daylight']) {
      await chooseTheme(member, theme);
      await capture(member, `shared-project-${theme}`);
    }
  } finally {
    await memberContext.close();
  }
});


test('slow navigation and requests show feedback until their response arrives', async ({ page }) => {
  await signIn(page);
  await expect(page.locator('#request-progress')).toBeHidden();
  await page.evaluate(() => window.liveSocket.enableLatencySim(700));
  await page.locator('.yard-nav a').filter({ hasText: 'Home' }).click();
  await expect(page.locator('#request-progress')).toBeVisible();
  await expect(page.locator('#request-progress')).toBeHidden();
  await page.locator('.yard-nav button').filter({ hasText: 'Add a repository' }).click();
  await expect(page.locator('#request-progress')).toBeVisible();
  await expect(page.locator('#new-project-dialog')).toBeVisible();
  await expect(page.locator('#request-progress')).toBeHidden();
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.locator('#new-project-dialog button.x').click();
  await expect(page.locator('#request-progress')).toBeVisible();
  await expect(page.locator('#request-progress .loading-spinner')).toHaveCSS('animation-name', 'none');
  await expect(page.locator('#request-progress')).toBeHidden();
  await page.evaluate(() => window.liveSocket.disableLatencySim());
});

test('a slow first connect shows skeletons and no request toast, never an empty inbox', async ({ page }) => {
  await signIn(page);
  // Whether the request toast was ever shown, however briefly: a retrying
  // `toBeHidden` would simply wait the first join out.
  await page.addInitScript(() => {
    window.__requestToast = false;
    // The document, not its root: parsing the page replaces the root element.
    new MutationObserver(() => {
      if (document.documentElement?.classList.contains('page-loading')) window.__requestToast = true;
    }).observe(document, { attributes: true, subtree: true, attributeFilter: ['class'] });
  });
  await page.evaluate(() => window.liveSocket.enableLatencySim(1500));
  try {
    await page.goto('/inbox');
    await expect(page.locator('#inbox-loading')).toBeVisible();
    await expect(page.locator('#rail-loading .rail-row-skeleton').first()).toBeVisible();
    await expect(page.locator('.inbox-empty')).toHaveCount(0);
    await expect(page.locator('[data-phx-main].phx-connected')).toHaveCount(1, { timeout: 15000 });
    await expect(page.locator('#inbox-loading')).toHaveCount(0, { timeout: 15000 });
    expect(await page.evaluate(() => window.__requestToast)).toBe(false);
  } finally {
    await page.evaluate(() => window.liveSocket.disableLatencySim());
  }
});

test('schedule Day appears only for weekly repetition without losing the draft', async ({ page }) => {
  await signIn(page);
  await page.goto('/schedules');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  const form = page.locator('#schedule-form');
  const day = form.getByLabel('Day', { exact: true });
  await expect(day).toHaveCount(0);
  await form.getByLabel('Name', { exact: true }).fill('Weekly review');
  await form.getByLabel('Prompt', { exact: true }).fill('Review recent changes');
  await form.getByLabel('Repeat', { exact: true }).selectOption('weekly');
  await expect(day).toBeVisible();
  await day.selectOption('5');
  for (const frequency of ['daily', 'hourly']) {
    await form.getByLabel('Repeat', { exact: true }).selectOption(frequency);
    await expect(day).toHaveCount(0);
  }
  await form.getByLabel('Repeat', { exact: true }).selectOption('weekly');
  await expect(day).toHaveValue('5');
  await expect(form.getByLabel('Name', { exact: true })).toHaveValue('Weekly review');
  await expect(form.getByLabel('Prompt', { exact: true })).toHaveValue('Review recent changes');
  await accessible(page);
});
