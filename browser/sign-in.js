import { expect } from '@playwright/test';

/**
 * Sign in through the provider mock as `login` and land on `landing`.
 *
 * Every wait here is load-bearing, which is why there is one helper rather
 * than a copy of these six lines per spec file.
 *
 * `phx-click` does nothing until the LiveView has connected: a click landing
 * in the gap between the static page painting and the socket joining is not
 * queued anywhere, it is simply lost. So "Skip setup" is pressed only once
 * the page says it is connected.
 *
 * Skipping is a server write --- `Accounts.finish_onboarding/1` --- and the
 * walkthrough is over only once that write lands. `WorkspaceLive` answers
 * `/`, `/home` and `/inbox` for anybody still unonboarded with a redirect
 * back to `/welcome`, and it answers the *static* render, so a plain
 * `page.goto` racing the skip is sent back to the walkthrough and nothing
 * the workspace draws is ever there. Waiting for the navigation the skip
 * itself causes is what proves the write happened.
 */
export async function signIn(page, login, landing = '/') {
  // `/` has nothing for a browser with no session and sends it here itself.
  await page.goto('/');
  await page.getByRole('link', { name: 'Sign in with GitHub', exact: true }).click();
  await page.getByRole('link', { name: `Sign in as @${login}`, exact: true }).click();
  // Signed in: the walkthrough offers "Sign out" outright, the workspace
  // behind the account menu that the person's own row opens.
  await expect(page.getByRole('link', { name: 'Sign out' }).or(page.locator('#account-trigger'))).toBeVisible();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  // Whoever signs in first, with no project yet, is shown the walkthrough.
  // One test is about that; every other test is about the workspace, and must
  // reach it whether or not it is the first to run.
  if (new URL(page.url()).pathname.startsWith('/welcome')) {
    await page.getByRole('button', { name: 'Skip setup', exact: true }).click();
    await expect(page).toHaveURL(/\/home$/);
  }
  await page.goto(landing);
  // The workspace's own buttons need the socket too, for the same reason.
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
}
