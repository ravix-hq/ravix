import {test, expect} from '@playwright/test';
import {signIn, connectClaude} from './sign-in.js';
import {openAddRepository} from './new-track.js';

// RAV-138: a tab open across a deploy keeps the old release's CSS and JS while
// its socket reconnects to the new one. The browser suite is the one that runs
// a digested build, so an earlier release is staged here: the page arrives
// naming a stylesheet digest this release never built, and that stylesheet is
// today's without the `.track-viewer` rules, the ones the reported case was
// missing when the Share button's avatar drew at full size over the header.
const OLD = '/assets/js/app-0000000000000000000000000000000.css';
const stylesheet = page => page.locator('link[phx-track-static][rel="stylesheet"]');

async function openTrack(page) {
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await openAddRepository(page);
  await page.getByLabel('Project name', {exact: true}).fill('ravix-stale');
  await page.getByRole('button', {name: 'Create scratch project', exact: true}).click();
  await page.locator('#top-new-track').click();
  await page.getByRole('button', {name: 'Create track', exact: true}).click();
  await expect(page.getByRole('textbox', {name: 'Message', exact: true})).toBeEnabled();
  return new URL(page.url()).pathname;
}

async function loadAsEarlierRelease(page, path) {
  const current = await stylesheet(page).getAttribute('href');
  const css = (await (await page.request.get(current)).text()).replace(/[^{}]*\.track-viewer[^{}]*\{[^}]*\}/g, '');
  await page.route(url => url.pathname === OLD, route => route.fulfill({body: css, contentType: 'text/css'}));
  await page.route(url => url.pathname === path, async route => {
    const response = await route.fetch();
    const body = (await response.text()).replace(/\/assets\/js\/app-[0-9a-f]+\.css/, OLD);
    // The mock's avatars are on its own port, which the page's CSP does not
    // allow; a GitHub avatar is on an https: origin, which it does.
    const headers = response.headers();
    headers['content-security-policy'] = headers['content-security-policy'].replace("img-src 'self'", "img-src 'self' http://localhost:*");
    await route.fulfill({response, body, headers});
  });
  // And Chromium will not load from another loopback port, so the avatar is
  // answered here, as the mock would.
  await page.route(url => url.pathname === '/ghweb/avatar.svg', async route => {
    await route.fulfill({response: await page.request.get(route.request().url())});
  });
  await page.reload();
  await expect(stylesheet(page)).toHaveAttribute('href', new RegExp(OLD));
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  return current;
}

test('a tab with an earlier release\'s assets is offered a reload, never given one, and Reload loads the current ones', async ({page}) => {
  const path = await openTrack(page);
  const current = await loadAsEarlierRelease(page, path);

  // The socket drops and comes back, as it does across a deploy.
  await page.evaluate(() => { window.beforeDeploy = true; });
  await page.evaluate(() => window.liveSocket.disconnect(() => window.liveSocket.connect()));
  const bar = page.getByRole('status').filter({hasText: 'Ravix was updated.'});
  await expect(bar).toBeVisible();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  // Nothing reloaded by itself: this is still the page that saw the deploy.
  expect(await page.evaluate(() => window.beforeDeploy)).toBe(true);

  // The avatar holds its own size with none of its rules, once it has
  // loaded: the mock's is 80px across, a GitHub one hundreds.
  const avatar = page.locator('.track-viewer img').first();
  await expect.poll(() => avatar.evaluate(img => img.complete && img.naturalWidth)).toBe(80);
  const box = await avatar.boundingBox();
  expect(box.width).toBeLessThanOrEqual(20);
  expect(box.height).toBeLessThanOrEqual(20);

  await page.unrouteAll();
  await Promise.all([page.waitForEvent('load'), bar.getByRole('button', {name: 'Reload', exact: true}).click()]);
  await expect(page).toHaveURL(new RegExp(`${path}$`));
  expect(await page.evaluate(() => window.beforeDeploy)).toBeUndefined();
  await expect(stylesheet(page)).toHaveAttribute('href', current);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.locator('#reload-bar')).toHaveCount(0);
});
