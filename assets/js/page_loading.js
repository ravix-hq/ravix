// Navigation has no clicked element for history changes. Pair LiveView's page
// events; overlapping requests must not hide feedback when only one finishes.
// Connection errors already have their own reconnect toast.
//
// The page's first join is not a request anybody is waiting on: the page
// already shows its skeletons (RAV-67). Until a join has once finished, an
// "initial" start is not counted, and neither is the stop that answers it.
// A rejoin after an established socket drops is counted as before.
export function trackPageLoading(target) {
  let pending = 0
  let joined = false
  let booting = false
  const paint = () => target.document.documentElement.classList.toggle("page-loading", pending > 0)
  const start = ({detail}) => {
    if (detail.kind === "initial" && !joined) {
      booting = true
      return
    }
    pending = detail.kind === "error" ? 0 : pending + 1
    paint()
  }
  const stop = () => {
    if (booting) {
      booting = false
      joined = true
      return
    }
    pending = Math.max(0, pending - 1)
    paint()
  }
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
