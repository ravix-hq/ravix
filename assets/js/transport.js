// Phoenix 1.8.15 stores this after an initial WebSocket failure. Retry the
// primary transport on each page load, without erasing LiveView history or
// forcing a working long-poll connection to reconnect on a blocked network.
export const LONG_POLL_FALLBACK_MS = 10_000

export function clearTransportFallback(browser) {
  try {
    browser.sessionStorage.removeItem("phx:fallback:LongPoll")
  } catch {
    // Storage can be denied by browser policy; cleanup must not prevent boot.
  }
}
