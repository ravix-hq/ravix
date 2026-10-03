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
 * back to `/welcome`, after loading the rail, so a plain
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
  // A connected workspace can still be deciding whether to send a first
  // visit to onboarding. Wait for that decision before inspecting the URL:
  // Sign-in lands on `/` (the Inbox) or the page it was asked for; each
  // draws a skeleton (Home's rows, the Inbox's cards, a project's
  // workspace crumb) until the rail is read.
  await expect(page.locator('body:not(:has(#rail-loading, #inbox-loading, #crumb-workspace-loading)) #topbar')
    .or(page.getByRole('button', { name: 'Skip setup', exact: true }))).toBeAttached();
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

/** Connect a mock Claude credential through the real account flow before spending it. */
export async function connectClaude(page) {
  const returnTo = new URL(page.url()).pathname + new URL(page.url()).search;
  await page.goto('/welcome/agent');
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  // The card says Connect or Connected once Fountain has said what is held.
  const status = page.locator('#agent-claude-status');
  const connect = page.getByRole('button', { name: 'Connect Claude Code', exact: true });
  await expect(status.getByText('Connected').or(connect)).toBeVisible();
  await expect(status).not.toContainText('Checking');
  if (await connect.isVisible()) {
    await connect.click();
    await page.getByLabel('Subscription token', { exact: true }).fill('sk-ant-oat01-browser-fixture');
    await page.getByRole('button', { name: 'Connect Claude Code', exact: true }).click();
    await expect(status).toContainText('Connected');
  }
  await page.goto(returnTo);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
}
