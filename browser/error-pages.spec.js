import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from './sign-in.js';

test('unknown pages retain the saved theme and offer a way home', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('ravix.theme', 'light'));
  const response = await page.goto('/no-such-page');
  expect(response.status()).toBe(404);
  await expect(page).toHaveTitle('Page not found · Ravix');
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('404 · Page not found');
  await expect(page.locator('main')).toHaveCSS('display', 'grid');
  await expect(page.getByRole('link', { name: 'Home', exact: true })).toHaveAttribute('href', '/home');
  const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);
  await page.getByRole('link', { name: 'Home', exact: true }).click();
  await expect(page.getByRole('heading', { level: 1 })).not.toHaveText('404 · Page not found');
});

test('signed in, an unknown page is a 404 inside the app shell with a way on', async ({ page }) => {
  // Its own person: `mockuser`'s first visit is another test's subject.
  await signIn(page, 'stagepages', '/home');
  const response = await page.goto('/no-such-page');
  expect(response.status()).toBe(404);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect(page).toHaveTitle('Page not found · Ravix');
  await expect(page.locator('#yard')).toBeVisible();
  await expect(page.locator('#not-found').getByRole('heading', { level: 1 })).toHaveText('Page not found');
  const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze();
  expect(result.violations).toEqual([]);
  await page.locator('#not-found-search').click();
  await expect(page.getByRole('dialog', { name: 'Search', exact: true })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog', { name: 'Search', exact: true })).toHaveCount(0);
  await page.locator('#not-found').getByRole('link', { name: 'Go to Inbox', exact: true }).click();
  await expect(page).toHaveURL(/\/inbox$/);
  await expect(page.locator('#inbox').getByRole('heading', { level: 1 })).toContainText('Inbox');
});
