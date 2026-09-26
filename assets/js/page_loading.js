// Navigation has no clicked element for history changes. Pair LiveView's page
// events; overlapping requests must not hide feedback when only one finishes.
// Connection errors already have their own reconnect toast.
export function trackPageLoading(target) {
  let pending = 0
  const paint = () => target.document.documentElement.classList.toggle("page-loading", pending > 0)
  const start = ({detail}) => {
    pending = detail.kind === "error" ? 0 : pending + 1
    paint()
  }
  const stop = () => { pending = Math.max(0, pending - 1); paint() }
  const reset = () => { pending = 0; paint() }
  target.addEventListener("phx:page-loading-start", start)
  target.addEventListener("phx:page-loading-stop", stop)
  const restored = (event) => { if (event.persisted) reset() }
  target.addEventListener("pageshow", restored)
  return () => {
    target.removeEventListener("phx:page-loading-start", start)
    target.removeEventListener("phx:page-loading-stop", stop)
    target.removeEventListener("pageshow", restored)
    reset()
  }
}
