import {beforeEach, expect, test} from 'bun:test'
import {TrackTabs} from '../js/hooks/track_tabs.js'
import {dimensions, mountHook} from './setup.js'

let strip, selected, revealed
beforeEach(() => {
  document.body.innerHTML = `<nav id="tabs"><button data-scroll-left></button><div class="track-tabs"><a href="/one" aria-current="page">One</a></div><button data-scroll-right></button></nav>`
  strip = document.querySelector('.track-tabs')
  dimensions(strip, {clientWidth: 200, scrollWidth: 800})
  let offset = 0
  Object.defineProperty(strip, 'scrollLeft', {configurable: true, get: () => offset, set: value => { offset = Math.max(0, Math.min(600, value)) }})
  strip.scrollBy = ({left}) => { strip.scrollLeft += left; strip.dispatchEvent(new Event('scroll')) }
  selected = strip.querySelector('a')
  revealed = 0
  selected.scrollIntoView = () => { revealed++ }
})
const wheel = options => {
  const event = new WheelEvent('wheel', {deltaY: 50, cancelable: true, ...options})
  // Happy DOM's WheelEvent omits modifier keys.
  Object.defineProperties(event, {ctrlKey: {value: !!options.ctrlKey}, shiftKey: {value: !!options.shiftKey}})
  strip.dispatchEvent(event)
  return event
}

test('mouse wheels scroll pixels, lines, and pages without intercepting native gestures or boundaries', () => {
  mountHook(TrackTabs, '#tabs')
  expect(wheel({}).defaultPrevented).toBe(true)
  expect(strip.scrollLeft).toBe(50)
  wheel({deltaMode: 1, deltaY: 2})
  expect(strip.scrollLeft).toBe(82)
  wheel({deltaMode: 2, deltaY: 1})
  expect(strip.scrollLeft).toBe(282)
  for (const options of [{ctrlKey: true}, {shiftKey: true}, {deltaX: 20}, {deltaY: 0}]) {
    expect(wheel(options).defaultPrevented).toBe(false)
    expect(strip.scrollLeft).toBe(282)
  }
  strip.scrollLeft = 600
  expect(wheel({}).defaultPrevented).toBe(false)
  expect(wheel({deltaY: -50}).defaultPrevented).toBe(true)
  expect(strip.scrollLeft).toBe(550)
})

test('controls reflect scroll limits and stop listening when destroyed', () => {
  const {hook} = mountHook(TrackTabs, '#tabs')
  expect(hook.left.disabled).toBe(true)
  expect(hook.right.disabled).toBe(false)
  hook.right.click()
  expect(strip.scrollLeft).toBe(160)
  expect(hook.left.disabled).toBe(false)
  hook.left.click()
  expect(strip.scrollLeft).toBe(0)
  strip.scrollLeft = 600
  strip.dispatchEvent(new Event('scroll'))
  expect(hook.right.disabled).toBe(true)
  hook.destroyed()
  hook.left.click()
  wheel({deltaY: -10})
  expect(strip.scrollLeft).toBe(600)
})

test('navigation reveals the selected tab while unrelated patches preserve manual scrolling', () => {
  const {hook} = mountHook(TrackTabs, '#tabs')
  expect(revealed).toBe(1)
  strip.scrollLeft = 100
  hook.updated()
  expect(revealed).toBe(1)
  expect(strip.scrollLeft).toBe(100)
  selected.setAttribute('href', '/two')
  hook.updated()
  expect(revealed).toBe(2)
  selected.removeAttribute('aria-current')
  hook.updated()
  expect(revealed).toBe(2)
  dimensions(strip, {scrollWidth: 200})
  strip.scrollLeft = 0
  hook.measure()
  expect(hook.left.disabled).toBe(true)
  expect(hook.right.disabled).toBe(true)
})
