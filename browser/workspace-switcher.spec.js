import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';

// RAV-96: the workspace menu drops down under a quiet down chevron, ticks the
// current workspace, and offers New workspace as a plain row. The switcher is
// drawn only with RAVIX_WORKSPACE_ACCESS on.
test('the workspace switcher points down and ticks the current workspace', async ({ page }) => {
  test.skip(process.env.RAVIX_WORKSPACE_ACCESS !== 'true', 'the switcher is behind RAVIX_WORKSPACE_ACCESS');
  await page.setViewportSize({ width: 1440, height: 900 });
  await signIn(page, 'sidebarpolish', '/home');
  const trigger = page.locator('#workspace-switcher-trigger');
  await expect(trigger).toBeVisible();
  await trigger.click();
  const menu = page.locator('#workspace-menu');
  await expect(menu).toBeVisible();
  await page.screenshot({ path: 'tmp/sidebar-workspace-menu.png', clip: { x: 0, y: 0, width: 320, height: 360 } });

  const chevron = trigger.locator('.workspace-chevron');
  expect(await chevron.evaluate(el => new DOMMatrix(getComputedStyle(el).transform).b)).toBeCloseTo(1);
  const current = menu.locator('[aria-current="true"]');
  await expect(current).toHaveCount(1);
  await expect(current.locator('.menu-check svg')).toBeVisible();
  await expect(menu.locator('[role="group"] button:not([aria-current]) .menu-check svg')).toHaveCount(0);
  const create = menu.getByRole('button', { name: 'New workspace…', exact: true });
  await expect(create).toHaveClass(/account-item/);
  await expect(create).not.toHaveClass(/primary/);
  await page.keyboard.press('Escape');
  expect((await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations).toEqual([]);
});
