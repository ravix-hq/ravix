import { test, expect } from '@playwright/test';
import { signIn, connectClaude } from './sign-in.js';

// RAV-54: an interactive terminal is a real shell on the track's machine,
// drawn by xterm.js. The mock's shell (mock/previews.ts) echoes, answers a
// few commands and replays its output on re-attach, as Sprites does.
test('terminal tabs: open, type, resize, several, reconnect, reload and close', async ({ page }) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'eli', '/home');
  await connectClaude(page);
  await page.getByRole('button', { name: 'Add a repository', exact: true }).first().click();
  await page.getByLabel('Project name', { exact: true }).fill('Terminal tabs');
  await page.getByRole('button', { name: 'Create scratch project', exact: true }).click();
  await page.locator('#yard .workspace-project.current .project-add').click();
  await page.getByRole('button', { name: 'Create track', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeEnabled();
  // The machine exists once setup has run; the chip says Idle then.
  await expect(page.locator('#track-machine-state')).toHaveText('Idle', { timeout: 30_000 });

  // "+" is a menu (RAV-101): New terminal is its first item.
  await page.locator('#dock-add-trigger').click();
  await expect(page.locator('#dock-add-menu')).toBeVisible();
  await page.getByRole('menuitem', { name: /New terminal/ }).click();
  await expect(page.locator('#dock-add-menu')).toBeHidden();
  const one = page.locator('.shell-pane:not([hidden]) .xterm');
  await expect(one).toBeVisible();
  // RAV-88: one prompt, naming the directory and not the machine's user or
  // host, drawn at the size the pane was fitted to before the shell started.
  await expect(one.locator('.xterm-rows')).toContainText(/\S+ \$ /, { timeout: 15_000 });
  await expect(page.locator('.shell-pane:not([hidden]) .shell-status')).toHaveCount(0);
  const drawn = await one.locator('.xterm-rows').innerText();
  expect(drawn).not.toContain('sprite@');
  expect(drawn).not.toContain('fountain-');
  expect(drawn.split('\n').filter(line => line.includes('$')).length).toBe(1);

  // Typing goes to the shell, which answers in the terminal.
  await page.keyboard.type('ls');
  await page.keyboard.press('Enter');
  await expect(one.locator('.xterm-rows')).toContainText('mix.exs');
  // A narrower window is a narrower terminal, and the shell is told: the
  // mock answers `stty size` with the size it was last sent.
  const size = async () => {
    await page.keyboard.type('stty size');
    await page.keyboard.press('Enter');
    await expect.poll(async () => (await one.locator('.xterm-rows').innerText()).match(/^(\d+) (\d+)$/gm)?.length ?? 0).toBeGreaterThan(sizes.length);
    const all = (await one.locator('.xterm-rows').innerText()).match(/^(\d+) (\d+)$/gm);
    sizes.push(all.at(-1));
    return all.at(-1);
  };
  const sizes = [];
  const wide = await size();
  // The size the shell was started at is the pane's: as many rows as xterm
  // draws, and nothing sent since has changed it.
  const [rows] = wide.split(' ').map(Number);
  expect(await one.locator('.xterm-rows > div').count()).toBe(rows);
  await page.waitForTimeout(500);
  expect(await size()).toBe(wide);
  await page.setViewportSize({ width: 1024, height: 900 });
  await expect.poll(size).not.toBe(wide);
  await page.setViewportSize({ width: 1440, height: 900 });

  await page.keyboard.type('iex -S mix');
  await page.keyboard.press('Enter');
  await expect(one.locator('.xterm-rows')).toContainText('iex(1)>');
  await page.keyboard.type('1 + 1');
  await page.keyboard.press('Enter');
  await expect(one.locator('.xterm-rows')).toContainText('iex(2)>');

  // A second tab is a second shell.
  // The second through its shortcut, from inside the first terminal.
  await page.keyboard.press('Control+Backquote');
  await expect(page.locator('[data-shell-tab]')).toHaveCount(2);
  const two = page.locator('.shell-pane:not([hidden]) .xterm');
  await expect(two.locator('.xterm-rows')).toContainText(/\S+ \$ /, { timeout: 15_000 });
  await expect(two.locator('.xterm-rows')).not.toContainText('iex(');
  await page.keyboard.type('git status');
  await page.keyboard.press('Enter');
  await expect(two.locator('.xterm-rows')).toContainText('working tree clean');

  // The LiveView socket drops and comes back: the terminal re-attaches, and
  // its output is replayed once, not twice.
  await page.evaluate(() => window.liveSocket.disconnect());
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-connected/);
  await page.evaluate(() => window.liveSocket.connect());
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(two.locator('.xterm-rows')).toContainText('working tree clean');
  await expect.poll(async () => ((await two.locator('.xterm-rows').innerText()).match(/working tree clean/g) || []).length).toBe(1);
  await page.keyboard.type('pwd');
  await page.keyboard.press('Enter');
  await expect(two.locator('.xterm-rows')).toContainText('/home/sprite/work/');

  // A reload is a new page: the tabs are still there, and so is the REPL.
  await page.reload();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.locator('[data-shell-tab]')).toHaveCount(2);
  await page.getByRole('button', { name: 'Terminal 1', exact: true }).click();
  const again = page.locator('.shell-pane:not([hidden]) .xterm');
  await expect(again.locator('.xterm-rows')).toContainText('iex(2)>', { timeout: 15_000 });

  // Closing a tab ends its shell; the other stays.
  await page.getByRole('button', { name: 'Close Terminal 1', exact: true }).click();
  await expect(page.locator('[data-shell-tab]')).toHaveCount(1);
  await expect(page.getByRole('button', { name: 'Terminal 2', exact: true })).toBeVisible();
  await page.reload();
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page.locator('[data-shell-tab]')).toHaveCount(1);
});
