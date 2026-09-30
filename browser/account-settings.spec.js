import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { signIn } from './sign-in.js';

test('the You menu\'s accessible name announces unseen changes and clears on acknowledgement', async ({ page }) => {
  await signIn(page, 'dana');
  const { database } = JSON.parse(readFileSync(`tmp/browser-${process.env.BROWSER_PORT || 4103}.json`, 'utf8'));
  if (!/^ravix_browser_[a-f0-9]{32}$/.test(database)) throw new Error('Not a browser database');
  const server = process.env.BROWSER_DATABASE_SERVER || 'postgres://postgres:postgres@localhost:5432';
  execFileSync('psql', [`${server}/${database}`, '-X', '-v', 'ON_ERROR_STOP=1', '-c',
    "UPDATE ravix.users SET created_at = '2000-01-01', changes_seen_at = NULL WHERE login = 'dana'"]);
  await page.reload();
  const trigger = page.locator('#account-trigger');
  await expect(trigger).toHaveAccessibleName(/^You, [1-9]\d* new in What's new$/);
  await trigger.click();
  await page.locator('#open-changes').click();
  await expect(page.locator('#changes-dialog')).toBeVisible();
  await expect(trigger).toHaveAccessibleName('You');
});
