// The browser's IANA time zone, sent with the LiveSocket's connect params so
// a new schedule runs at the creator's wall-clock time and schedule times are
// shown in the viewer's zone. The server validates it against its own zone
// database and uses UTC for anything it does not know, so this only has to
// report what the browser says, or nothing when it cannot say.
export function browserTimeZone(intl = globalThis.Intl) {
  try {
    const zone = intl.DateTimeFormat().resolvedOptions().timeZone
    return typeof zone === "string" ? zone : ""
  } catch (_error) {
    return ""
  }
}
