import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { composerFixture } from './composer-fixture.js';

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

async function signIn(page) {
  // `/` has nothing for a browser with no session and sends it here itself.
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
  await page.getByRole('link', { name: 'Sign in as @mockuser', exact: true }).click();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  // Whoever signs in first, with no project yet, is shown the walkthrough. The
  // test below is about that; every other test is about the workspace, and
  // must reach it whether or not it is the first to run.
  if (new URL(page.url()).pathname.startsWith('/welcome')) {
    await page.getByRole('button', { name: 'Skip setup', exact: true }).click();
    await expect(page).toHaveURL(/\/home$/);
    await page.goto('/');
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  }
}

async function chooseTheme(page, name) {
  await page.locator('[data-theme-toggle]').click();
  await page.getByRole('menuitemradio', { name, exact: true }).click({ timeout: 15_000 });
  await expect(page.locator('html')).toHaveAttribute('data-theme', name.toLowerCase());
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

test('a first visit is walked through how it works, the agent, and GitHub', async ({ page }) => {
  test.setTimeout(120_000);
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
  await page.getByRole('link', { name: 'Sign in as @mockuser', exact: true }).click();

  // Nobody chose to be here, so this is where a first visit lands.
  await expect(page).toHaveURL(/\/welcome$/);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.getByRole('heading', { name: /^Welcome to Ravix/ })).toBeVisible();
  for (const idea of ['A project is a repository.', 'Every project has a computer.', 'A project holds many conversations.', 'Invite teammates, and you are the one billed.']) {
    await expect(page.getByText(idea, { exact: true })).toBeVisible();
  }
  await accessible(page);
  await capture(page, 'welcome-intro');

  await page.getByRole('link', { name: 'Set up your agent', exact: true }).click();
  await expect(page).toHaveURL(/\/welcome\/agent$/);

  // Codex on a ChatGPT subscription is a sign-in, not a paste: the page shows
  // the code the mock Fountain hands out and notices the approval by itself
  // (the mock approves on the third poll). Nothing here is ever a token.
  await page.getByRole('button', { name: /^Codex/ }).click();
  await expect(page.getByRole('button', { name: 'Subscription', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByLabel('API key', { exact: true })).toHaveCount(0);
  await accessible(page);
  await page.getByRole('button', { name: 'Connect ChatGPT', exact: true }).click();
  await expect(page.locator('#chatgpt-user-code')).toHaveText('MOCK-CODE');
  await expect(page.getByRole('link', { name: 'https://auth.openai.com/codex/device' })).toHaveAttribute('target', '_blank');
  await accessible(page);
  await capture(page, 'welcome-chatgpt');
  await expect(page).toHaveURL(/\/welcome\/github$/, { timeout: 15_000 });
  expect(await page.content()).not.toContain('MOCK-CODE');

  // Back to the agent step by hand: Claude Code takes a pasted token.
  await page.goto('/welcome/agent');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.getByText('Codex is connected with your ChatGPT subscription')).toBeVisible();
  await page.getByRole('button', { name: /^Claude Code/ }).click();
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
  await expect(page).toHaveURL(/\/welcome\/github$/);
  expect(await page.content()).not.toContain('sk-ant-oat01-mock');
  await expect(page.getByRole('heading', { name: 'Connect GitHub' })).toBeVisible();
  await expect(page.locator('#github-connected, #github-none')).toBeVisible();
  await accessible(page);
  await capture(page, 'welcome-github');

  // Coming back part way through carries on from here, not from the top.
  await page.goto('/');
  await expect(page).toHaveURL(/\/welcome\/github$/);

  await page.locator('#github-continue').click();
  await expect(page).toHaveURL(/\/welcome\/project$/);
  await expect(page.getByRole('heading', { name: 'Create your first project' })).toBeVisible();
  await accessible(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await accessible(page);
  await capture(page, 'welcome-project-mobile');

  // Leaving is finishing: the workspace stops sending this person back, and
  // the tests after this one start from an empty workspace as they always did.
  await page.getByRole('button', { name: 'Skip setup', exact: true }).click();
  await expect(page).toHaveURL(/\/home$/);
  await page.goto('/');
  await expect(page.getByRole('heading', { name: /Inbox/ })).toBeVisible();
});

test('the account dialog is where the agent lives after the walkthrough', async ({ page }) => {
  await signIn(page);
  await page.getByRole('button', { name: 'account', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Your account' })).toBeVisible();
  await expect(page.getByRole('group', { name: 'Agent' })).toBeVisible();
  await accessible(page);
  await capture(page, 'account-dialog');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog', { name: 'Your account' })).toHaveCount(0);
});

test('home quick start creates a scratch project and recent navigation survives theme changes', async ({ page }) => {
  await signIn(page);
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  await expect(page.getByRole('button', { name: /Open a local project/ })).toBeDisabled();
  await accessible(page);
  await capture(page, 'home-empty');
  await page.getByRole('button', { name: /^Quick start/ }).click();
  await page.getByLabel('Project name', { exact: true }).fill('Quick start quality');
  await expect(page.getByLabel('Repository', { exact: true })).toHaveValue('');
  await page.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Pick a track' })).toBeVisible();
  await expect(page.locator('.crumbs')).toContainText('Quick start quality');
  await capture(page, 'project-empty');
  await page.getByRole('link', { name: 'Home', exact: true }).first().click();
  const recent = page.getByRole('region', { name: 'Recent projects' });
  await expect(recent).toContainText('Quick start quality');
  await expect(recent).toContainText('no repository');
  for (const theme of ['Ravix', 'Daylight']) {
    await chooseTheme(page, theme);
    await accessible(page);
    await capture(page, `home-${theme}`);
  }
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'daylight');
  await recent.getByRole('link', { name: /Quick start quality/ }).click();
  await expect(page.getByRole('heading', { name: 'Pick a track' })).toBeVisible();
  await expect(page.locator('.crumbs')).toContainText('Quick start quality');
  // Exact: an empty inbox must not put a "0" badge in the link's name.
  await page.getByRole('link', { name: 'Inbox', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: "You're all caught up" })).toBeVisible();
  await accessible(page);
  await capture(page, 'inbox-Daylight');
  await page.setViewportSize({ width: 390, height: 844 });
  const mobileNav = page.getByRole('navigation', { name: 'Workspace navigation' });
  await mobileNav.getByRole('link', { name: 'Home' }).click();
  await accessible(page);
  await capture(page, 'home-mobile');
  // The rail is gone at this width, and everything in it --- signing out,
  // the theme picker, the account --- was unreachable until Menu brought it
  // back over the page. Following a link in it closes it again.
  const menu = mobileNav.getByRole('button', { name: 'Menu' });
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeHidden();
  await expect(menu).toHaveAttribute('aria-expanded', 'false');
  await menu.click();
  await expect(menu).toHaveAttribute('aria-expanded', 'true');
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Close menu' })).toBeVisible();
  await accessible(page);
  await capture(page, 'home-mobile-menu');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeHidden();
  await menu.click();
  await page.getByRole('complementary', { name: 'Projects and tracks' }).getByRole('link', { name: 'Inbox' }).click();
  await expect(page.getByRole('heading', { name: "You're all caught up" })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeHidden();
  await expect(menu).toHaveAttribute('aria-expanded', 'false');
});

test('keyboard users can resize panels and close dialogs with focus restored', async ({ page }) => {
  await signIn(page);
  const handle = page.getByRole('separator', { name: 'Sidebar width' });
  await handle.focus();
  await handle.press('Home');
  await expect(handle).toHaveAttribute('aria-valuenow', '220');
  await handle.press('ArrowRight');
  await expect(handle).toHaveAttribute('aria-valuenow', '230');
  const open = page.getByRole('complementary', { name: 'Projects and tracks' }).getByRole('button', { name: 'Add a project', exact: true }).first();
  await open.focus();
  await open.press('Enter');
  const dialog = page.getByRole('dialog', { name: 'New project' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('button', { name: 'Close', exact: true })).toBeFocused();
  await accessible(page);
  await page.keyboard.press('Escape');
  await expect(dialog).not.toBeVisible();
  await expect(open).toBeFocused();
});

test('project, track, streaming, image upload, reconnect, and revocation', async ({ page, context }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await signIn(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const projectDialog = page.getByRole('dialog', { name: 'New project' });
  await expect(projectDialog).toBeVisible();
  await page.getByLabel('Project name', { exact: true }).fill('Browser quality');
  await expect(page.getByLabel('Repository', { exact: true }).locator('option')).not.toHaveCount(1);
  await page.getByLabel('Repository', { exact: true }).selectOption('mockuser/atlas-api');
  await projectDialog.getByRole('button', { name: 'Create project' }).click();
  await expect(projectDialog).not.toBeVisible();
  await page.locator('.crumbs').getByRole('button', { name: 'New track', exact: true }).click();
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await expect(newTrack.getByLabel('Branch name')).toHaveValue('');
  await newTrack.getByRole('button', { name: 'Advanced', exact: true }).click();
  await expect(newTrack.getByRole('button', { name: 'Branch', exact: true })).toBeVisible();
  await newTrack.getByRole('button', { name: 'Hide advanced', exact: true }).click();
  await expect(newTrack.getByRole('button', { name: 'Branch', exact: true })).not.toBeVisible();
  await capture(page, 'new-track');
  await page.getByLabel('Branch name').fill('browser-smoke');
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
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
  await expect(page.locator('.file-diff')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await capture(page, 'changes-diff-mobile');
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.getByRole('button', { name: '← All changed files' }).click();
  await expect(page.getByLabel('Filter paths')).toHaveValue('window');
  await page.getByRole('button', { name: 'All files', exact: true }).click();

  await accessible(page);
  await expect(page.locator('.crumbs')).toHaveCount(1);
  const collapseProject = page.getByRole('button', { name: 'Collapse Browser quality', exact: true });
  await collapseProject.click();
  await expect(page.getByRole('link', { name: /browser-smoke/ })).not.toBeVisible();
  await page.getByRole('button', { name: 'Expand Browser quality', exact: true }).click();
  await expect(page.getByRole('link', { name: /browser-smoke/ })).toBeVisible();
  await expect(page.getByLabel('Command', { exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Terminal', exact: true }).click();
  await page.getByLabel('Command', { exact: true }).fill('echo draft');
  await page.getByRole('button', { name: 'Collapse the dock' }).click();
  await expect(page.getByLabel('Command', { exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Expand the dock' }).click();
  await expect(page.getByLabel('Command', { exact: true })).toHaveValue('echo draft');
  await page.getByRole('button', { name: 'Machine stats', exact: true }).click();
  await expect(page.getByLabel('Command', { exact: true })).not.toBeVisible();
  await page.getByRole('button', { name: 'Terminal', exact: true }).click();
  await expect(page.getByLabel('Command', { exact: true })).toHaveValue('echo draft');
  await page.getByRole('button', { name: 'Collapse the dock' }).click();
  await composer.fill('A draft while opening workspace dialogs');
  const newTrackTrigger = page.locator('.crumbs').getByRole('button', { name: 'New track', exact: true });
  await newTrackTrigger.click();
  await expect(newTrack).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(newTrackTrigger).toBeFocused();
  await expect(composer).toHaveValue('A draft while opening workspace dialogs');
  await page.locator('.crumbs').getByRole('button', { name: 'Settings', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Project settings', exact: true });
  await expect(settings).toBeVisible();
  await settings.getByRole('button', { name: 'Danger zone', exact: true }).click();
  const removeProject = settings.getByRole('button', { name: 'Delete project', exact: true });
  await removeProject.scrollIntoViewIfNeeded();
  await expect(removeProject).toBeInViewport();
  await expect(settings.getByRole('button', { name: 'Close', exact: true })).toBeInViewport();
  await capture(page, 'settings');
  await page.keyboard.press('Escape');
  await expect(composer).toHaveValue('A draft while opening workspace dialogs');
  await composer.fill('Explain this project for the browser smoke test');
  await composer.press('Enter');
  // The saved-prompts panel exists for exactly this window: accepted, and
  // waiting while the machine works. It is also the panel a template bug
  // once crashed the page on, which this suite caught only by accident.
  // One locator for the prompt and its status chip: the panel leaves as soon
  // as the machine takes the prompt, so two separate checks can each see a
  // different render and the second one finds nothing.
  await expect(page.locator('.workspace-queue > div', { has: page.locator('.chip') })).toContainText('Explain this project for the browser smoke test');
  // The prompt's own bubble, not just the page: the mock's reply quotes the
  // prompt back, so the transcript contains these words even when the prompt
  // never arrived. It reaches the live page on the turn's opening event, which
  // the follower reads back from the feed because the stream never carries it.
  await expect(page.locator('#transcript-turns .said .workspace-prompt').filter({ hasText: 'Explain this project for the browser smoke test' })).toHaveCount(1);
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Explain this project for the browser smoke test' }).locator('.md')).toContainText('There is one TODO worth doing here');
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
  const chooserOpened = page.waitForEvent('filechooser');
  await page.getByRole('button', { name: 'Choose images', exact: true }).click();
  const chooser = await chooserOpened;
  await chooser.setFiles({
    name: 'pixel.png', mimeType: 'image/png',
    buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4WQAAAAASUVORK5CYII=', 'base64'),
  });
  await expect(page.locator('.workspace-upload')).toContainText('pixel.png');
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.locator('.workspace-upload')).toHaveCount(0);
  await expect(page.locator('.workspace-turn').filter({ hasText: 'Draft survives reconnect' }).locator('.md')).toContainText('There is one TODO worth doing here');
  await capture(page, 'track-Ravix');
  await chooseTheme(page, 'Daylight');
  await accessible(page);
  await capture(page, 'track-Daylight');
  await page.setViewportSize({ width: 390, height: 844 });
  await accessible(page);
  await capture(page, 'track-mobile');
  // On a phone the project's own controls live in the yard, and the yard is
  // behind Menu. The owner's "Project settings" is the one worth proving
  // reachable, because nothing else on the page offers it at this width.
  const trackMenu = page.getByRole('navigation', { name: 'Workspace navigation' }).getByRole('button', { name: 'Menu' });
  await expect(page.getByRole('button', { name: 'Project settings' })).toBeHidden();
  await trackMenu.click();
  await expect(page.getByRole('button', { name: 'Project settings' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Sign out' })).toBeVisible();
  await accessible(page);
  await capture(page, 'track-mobile-menu');
  await page.getByRole('button', { name: 'Close menu' }).click();
  await expect(page.getByRole('button', { name: 'Project settings' })).toBeHidden();
  await page.setViewportSize({ width: 1280, height: 720 });
  // The same session is revoked from a second tab while the first remains connected.
  const trackURL = page.url();
  await composer.fill("This must never be sent");
  const other = await context.newPage();
  await other.goto('/home');
  await other.getByRole('link', { name: 'Sign out' }).click();
  await expect(other.getByRole('heading', { name: 'Sign in to Ravix' })).toBeVisible();
  await page.evaluate(() => document.querySelector("#composer-form")?.requestSubmit());
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
  await page.locator('.crumbs').getByRole('button', { name: 'New track', exact: true }).click();
  await expect(newTrack).toBeVisible();
  await page.getByLabel('Branch name').fill('second-lane');
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText('second-lane');
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  await expect(page.locator('#transcript-scroll')).not.toHaveAttribute('data-track', firstLane);
  // The track arrived at is its own; the one left behind had three turns in it.
  await expect(page.locator('#transcript-turns')).not.toContainText('Draft survives reconnect');
  await accessible(page);

  await page.getByRole('link', { name: /browser-smoke/ }).click();
  await expect(page.locator('.track-crumbs')).toContainText('browser-smoke');
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

test('help explains desktop connections and stays accessible on mobile', async ({ page }) => {
  await signIn(page);
  const help = page.getByRole('button', { name: 'Help', exact: true });
  await help.click();
  const dialog = page.getByRole('dialog', { name: 'Help · AI tools' });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText(`claude mcp add --transport http ravix http://localhost:${process.env.BROWSER_PORT || 4103}/mcp`, { exact: true })).toBeVisible();
  await dialog.getByText('Drive tracks with an A2A client', { exact: true }).click();
  await expect(dialog.getByText(`http://localhost:${process.env.BROWSER_PORT || 4103}/.well-known/agent-card.json`, { exact: true })).toBeVisible();
  await dialog.getByText('Example JSON-RPC request', { exact: true }).click();
  await expect(dialog.locator('pre').filter({ hasText: 'SendMessage' })).toBeVisible();
  await accessible(page);
  await capture(page, 'tooling-help');
  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(help).toBeFocused();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('navigation', { name: 'Workspace navigation' }).getByRole('button', { name: 'Menu' }).click();
  await help.click();
  await expect(dialog).toBeVisible();
  await dialog.getByText('Permissions, progress and disconnecting', { exact: true }).click();
  await expect(dialog.getByRole('link', { name: 'Connected applications' })).toHaveAttribute('href', '/settings/connections');
  await accessible(page);
  await capture(page, 'tooling-help-mobile');
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await expect(dialog).toHaveCount(0);
});

test('project settings navigate, warn before discarding, and save sections accessibly', async ({ page }) => {
  await signIn(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const create = page.getByRole('dialog', { name: 'New project' });
  await create.getByLabel('Project name', { exact: true }).fill('Settings browser');
  await create.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(create).not.toBeVisible();
  await page.locator('.crumbs').getByRole('button', { name: 'Settings', exact: true }).click();
  const settings = page.getByRole('dialog', { name: 'Project settings', exact: true });
  await settings.getByLabel('Name', { exact: true }).fill('Unsaved name');
  await expect(settings.getByRole('status')).toHaveText('Unsaved changes');
  page.once('dialog', dialog => dialog.dismiss());
  await settings.getByRole('button', { name: 'Agent', exact: true }).click();
  await expect(settings.getByLabel('Name', { exact: true })).toBeVisible();
  page.once('dialog', dialog => dialog.accept());
  await settings.getByRole('button', { name: 'Agent', exact: true }).click();
  await expect(settings.getByRole('heading', { name: 'Agent', exact: true })).toBeFocused();
  await settings.getByLabel('Instructions', { exact: true }).fill('Explain changes and run focused tests.');
  await settings.getByRole('button', { name: 'Save agent', exact: true }).click();
  await expect(settings.getByRole('status')).toHaveText('Saved.');
  await accessible(page);
  await settings.getByRole('button', { name: 'General', exact: true }).click();
  await expect(settings.getByLabel('Name', { exact: true })).toHaveValue('Settings browser');
  await settings.getByLabel('Name', { exact: true }).fill('Settings organized');
  await settings.getByRole('button', { name: 'Save general', exact: true }).click();
  await expect(settings.getByRole('status')).toHaveText('Saved.');
  await settings.getByRole('button', { name: 'Previews', exact: true }).click();
  await settings.getByLabel('Command (must honor $PORT)', { exact: true }).fill('npm run dev');
  await settings.getByRole('button', { name: 'Save defaults', exact: true }).click();
  await expect(settings.locator('.field p.error')).toBeVisible();
  await settings.getByLabel('Command (must honor $PORT)', { exact: true }).fill('npm run dev -- --port "$PORT" --strictPort');
  await settings.getByLabel('Readiness path', { exact: true }).fill('/health');
  await settings.getByRole('button', { name: 'Save defaults', exact: true }).click();
  await expect(settings.getByRole('status')).toHaveText('Saved.');
  for (const section of ['Environment', 'Secrets', 'Danger zone']) {
    await settings.getByRole('button', { name: section, exact: true }).click();
    await accessible(page);
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await settings.getByRole('button', { name: 'Agent', exact: true }).click();
  await expect(settings.getByLabel('Instructions', { exact: true })).toHaveValue('Explain changes and run focused tests.');
  await accessible(page);
  await capture(page, 'settings-mobile');
  await page.keyboard.press('Escape');
  await expect(settings).not.toBeVisible();
});

test('composer Send stays compact and keeps its arrow after repeated submissions in every theme', async ({ page, request }) => {
  // Five states x 22 palettes x 2 widths runs in ~30s locally; allow CI headroom.
  test.setTimeout(120_000);
  await signIn(page);
  await page.getByRole('button', { name: 'Add a project', exact: true }).first().click();
  const projectDialog = page.getByRole('dialog', { name: 'New project', exact: true });
  await projectDialog.getByLabel('Project name', { exact: true }).fill('Send regression');
  await projectDialog.getByRole('button', { name: 'Create project', exact: true }).click();
  await expect(projectDialog).toHaveCount(0);
  await page.locator('.crumbs').getByRole('button', { name: 'New track', exact: true }).click();
  // New tracks are named after their reserved ravix/ branch (#154).
  const newTrack = page.getByRole('dialog', { name: 'New track', exact: true });
  await newTrack.getByLabel('Branch name', { exact: true }).fill('compact-send');
  await newTrack.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.locator('.track-crumbs')).toContainText('compact-send');
  const composer = page.getByRole('textbox', { name: 'Message', exact: true });
  const send = page.getByRole('button', { name: 'Send', exact: true });
  await expect(composer).toBeEnabled({ timeout: 30_000 });
  const checkSend = async () => {
    await expect(send).toBeVisible();
    const box = await send.boundingBox();
    expect(box.width).toBeLessThanOrEqual(80);
    expect(box.height).toBeLessThanOrEqual(44);
    expect(box.width).toBeGreaterThanOrEqual(32);
    expect(box.height).toBeGreaterThanOrEqual(32);
    await expect(send).toHaveText('Send');
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
    await expect(page.locator('.send-hint')).toContainText('Enter');
    await fitsViewport(page);
  };
  await chooseTheme(page, 'Bubblegum');
  // Sending previously destroyed the SVG. Exercise both mouse and Enter, and
  // inspect during the LiveView acknowledgement window as well as afterwards.
  await page.evaluate(() => window.liveSocket.enableLatencySim(200));
  for (const method of ['click', 'Enter']) {
    await composer.fill(`Send regression ${method}`);
    if (method === 'click') await send.click();
    else await composer.press('Enter');
    await expect(page.locator('#composer-form')).toHaveClass(/phx-submit-loading/);
    await checkSend();
    await expect(composer).toHaveValue('');
    await expect(send).toBeEnabled();
    await checkSend();
  }
  await page.evaluate(() => window.liveSocket.disableLatencySim());
  await expect(page.locator('#transcript-turns')).toContainText('Send regression Enter');
  await expect(page.locator('#composer-form').getByRole('button', { name: 'Stop', exact: true })).toHaveCount(0, { timeout: 30_000 });
  const fixture = composerFixture(new URL(page.url()).pathname.split('/').pop());
  const palettes = await page.locator('[data-theme-choice]').evaluateAll(els => [...new Set(els.map(el => el.dataset.themeChoice))]);
  expect(palettes).toHaveLength(22);
  for (const [status, connected] of [['opening', false], ['opening', true], ['running', true], ['ready', true], ['failed', true]]) {
    await fixture.state(request, status, connected);
    await page.reload();
    await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
    await expect(send).toBeVisible();
    if (connected) await expect(send).toBeEnabled();
    else await expect(send).toBeDisabled();
    await expect(page.locator('#composer-form').getByRole('button', { name: 'Stop', exact: true })).toHaveCount(['opening', 'running'].includes(status) ? 1 : 0);
    await expect(page.locator('#composer-form').getByRole('button', { name: 'Wake / retry', exact: true })).toHaveCount(['opening', 'failed'].includes(status) ? 1 : 0);
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
        await test.step(`${status}, connected=${connected}, ${theme}, ${width}px`, checkSend);
        if (theme === 'bubblegum') await page.screenshot({ path: test.info().outputPath(`send-${status}-${connected}-${width}.png`), fullPage: true });
      }
    }
  }
});
