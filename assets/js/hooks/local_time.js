// A `<time datetime>` written in the viewer's own zone and locale: the time
// alone for today ("12:15 PM", or "12:15" where the locale says 24-hour),
// the date and time before that ("Sep 28, 4:27 PM"), and the year as well
// once it is not this one. The `title` spells it out with the zone's name.
// With `data-weekday` (a turn's footer, RAV-93) the six days before today
// are named by weekday instead: "Sat 9:49 PM".
//
// The server renders the same shape in the zone the browser reported on
// connect (UTC when it reported none), so the text reads right before this
// runs and in tests. Nothing ticks: a time that was "today" at render stays
// written as a time until the next render, which is what a clock would show.

const fields = zone => (zone ? {timeZone: zone} : {})

// The calendar day of `at` in `zone`, as a comparable string.
function day(at, zone) {
  return new Intl.DateTimeFormat('en-CA', {...fields(zone), year: 'numeric', month: '2-digit', day: '2-digit'})
    .format(at)
}

function year(at, zone) {
  return new Intl.DateTimeFormat('en-CA', {...fields(zone), year: 'numeric'}).format(at)
}

// Whole calendar days from `at` to `today`, both read in `zone`.
function daysBefore(at, today, zone) {
  return Math.round((Date.parse(day(today, zone)) - Date.parse(day(at, zone))) / 86_400_000)
}

export function localTime(then, {now = Date.now(), timeZone, locale, weekday = false} = {}) {
  const at = new Date(then)
  const today = new Date(now)
  const time = new Intl.DateTimeFormat(locale, {...fields(timeZone), hour: 'numeric', minute: '2-digit'}).format(at)
  if (day(at, timeZone) === day(today, timeZone)) return time
  const ago = daysBefore(at, today, timeZone)
  if (weekday && ago > 0 && ago < 7) {
    return `${new Intl.DateTimeFormat(locale, {...fields(timeZone), weekday: 'short'}).format(at)} ${time}`
  }

  const options = {...fields(timeZone), month: 'short', day: 'numeric'}
  if (year(at, timeZone) !== year(today, timeZone)) options.year = 'numeric'
  return `${new Intl.DateTimeFormat(locale, options).format(at)}, ${time}`
}

export function fullTime(then, {timeZone, locale} = {}) {
  return new Intl.DateTimeFormat(locale, {
    ...fields(timeZone),
    weekday: 'short',
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZoneName: 'long',
  }).format(new Date(then))
}

function render(el) {
  const then = Date.parse(el.getAttribute('datetime'))
  if (Number.isNaN(then)) return
  const text = localTime(then, {weekday: 'weekday' in el.dataset})
  if (el.textContent !== text) el.textContent = text
  el.title = `${el.dataset.titlePrefix || ''}${fullTime(then)}`
}

export const LocalTime = {
  mounted() { render(this.el) },
  updated() { render(this.el) },
}
