// Whether the viewer is on an Apple platform, where shortcuts take ⌘ rather
// than Ctrl. Sent with the LiveSocket's connect params so the server labels
// shortcut hints for the viewer (⌘K or Ctrl K), and read by the hooks that
// bind them, so the label and the binding cannot disagree.
export function macPlatform(nav = globalThis.navigator) {
  return /mac|iphone|ipad|ipod/i.test(nav?.userAgentData?.platform || nav?.platform || "")
}
