// One Escape closes the topmost thing. LiveView runs every
// `phx-window-keydown` binding for a key, so an open dialog, the phone's
// yard scrim and the plan items popover all heard the same press. Whether a
// dialog was open is noted in the capture phase, before any binding runs and
// before the dialog's own close hides it, and each keydown event carries that
// as `dialog`; the handlers underneath a dialog ignore an Escape that has it.
export function watchDialogs(target) {
  const underDialog = new WeakSet()
  const note = (e) => {
    if (e.key === "Escape" && openDialog(target.document)) underDialog.add(e)
  }
  target.addEventListener("keydown", note, true)
  return {
    keydown: (e) => (underDialog.has(e) ? {dialog: true} : {}),
    stop: () => target.removeEventListener("keydown", note, true),
  }
}

// A closing dialog is `hidden` until the server removes it; it is not open.
const openDialog = (doc) => [...doc.querySelectorAll(".scrim")].some((scrim) => !scrim.hidden)
