import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

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
