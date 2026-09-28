import {test, expect} from '@playwright/test';
import {signIn} from './sign-in.js';
import {LONG_POLL_FALLBACK_MS} from '../assets/js/transport.js';

// Preserve mockuser's first-visit state for workspace.spec.js.
const transport = page => page.evaluate(() => {
  const socket = window.liveSocket.getSocket();
  return socket.transportName(socket.transport);
});

test('normal load uses WebSocket', async ({page}) => {
  await signIn(page, 'eli');
  await expect.poll(() => transport(page)).toBe('WebSocket');
  expect(await page.evaluate(() => window.liveSocket.getSocket().conn instanceof WebSocket)).toBe(true);
});

test('stalled WebSocket falls back after the deadline; reload retries WebSocket', async ({page}) => {
  await signIn(page, 'eli');
  // Simulate a network that silently drops the handshake, rather than emitting
  // an error (Phoenix deliberately falls back immediately on explicit errors).
  await page.addInitScript(() => {
    if (sessionStorage.getItem('test:stall-websocket') !== 'true') return;
    sessionStorage.removeItem('test:stall-websocket');
    window.WebSocket = class extends EventTarget {
      static CONNECTING = 0;
      static OPEN = 1;
      static CLOSING = 2;
      static CLOSED = 3;
      readyState = 0;
      bufferedAmount = 0;
      constructor() {
        super();
        window.websocketAttemptAt = performance.now();
      }
      send() {}
      close() { this.readyState = 3; }
    };
  });
  await page.evaluate(() => sessionStorage.setItem('test:stall-websocket', 'true'));
  await page.reload();
  await page.waitForFunction(() => window.websocketAttemptAt !== undefined);
  expect(await page.evaluate(() => window.liveSocket.getSocket().longPollFallbackMs)).toBe(LONG_POLL_FALLBACK_MS);

  const firstPoll = await page.waitForRequest(request => request.url().includes('/live/longpoll'));
  expect(firstPoll.method()).toBe('GET');
  const elapsed = await page.evaluate(() => performance.now() - window.websocketAttemptAt);
  expect(elapsed).toBeGreaterThanOrEqual(LONG_POLL_FALLBACK_MS - 100);
  expect(elapsed).toBeLessThan(LONG_POLL_FALLBACK_MS + 5_000);
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect.poll(() => transport(page)).toBe('LongPoll');
  expect(await page.evaluate(() => sessionStorage.getItem('phx:fallback:LongPoll'))).toBe('true');
  // Prove a real LiveView event still works over the fallback transport.
  await page.locator('#account-trigger').click();
  await expect(page.locator('#account-menu')).toBeVisible();
  await page.locator('#open-help').click();
  await expect(page.getByRole('dialog')).toBeVisible();

  const upgraded = page.waitForEvent('websocket', ws => ws.url().includes('/live/websocket'));
  await page.reload();
  await upgraded;
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/);
  await expect.poll(() => transport(page)).toBe('WebSocket');
  expect(await page.evaluate(() => sessionStorage.getItem('phx:fallback:LongPoll'))).toBeNull();
});
