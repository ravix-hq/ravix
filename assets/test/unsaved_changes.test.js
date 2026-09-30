import {afterEach, beforeEach, expect, test} from 'bun:test'
import {UnsavedChanges} from '../js/hooks/unsaved_changes.js'
import {key, mountHook} from './setup.js'

// A link's default action would load a page in happy-dom; whether anything
// prevented it is noted first, and `click` answers that.
const follow = event => { event.followed = !event.defaultPrevented; event.preventDefault() }
beforeEach(() => window.addEventListener('click', follow))
afterEach(() => window.removeEventListener('click', follow))

// The markup `RavixWeb.Live.Settings.unsaved_changes/1` renders, inside a
// page with LiveView's own patch and navigate links around it.
beforeEach(() => {
  document.body.innerHTML = `
    <nav>
      <a id="patch" href="/w/1/settings/members" data-phx-link="patch" data-phx-link-state="push">Members</a>
      <a id="navigate" href="/p/1" data-phx-link="redirect" data-phx-link-state="push">Project</a>
      <a id="plain" href="/api/auth/install">Repository access</a>
      <a id="hash" href="#workspace-github">GitHub</a>
      <a id="blank" href="/elsewhere" target="_blank">New tab</a>
      <div id="menu-popover" popover><button id="switch" type="button" data-leaves-page>Other workspace</button></div>
      <button id="menu" type="button">Menu</button>
    </nav>
    <div id="unsaved" data-saved="0" data-discard-event="discard-general" data-discard-target="3">
      <form id="general"><input id="name" name="name" value="Acme"><input id="secret" type="password"></form>
      <div data-unsaved-ignore><form><input id="confirm"></form></div>
      <div id="unsaved-bar" data-unsaved-bar hidden>
        Unsaved changes · <button type="button" data-unsaved-discard>Discard</button>
        <button type="submit" form="general" data-unsaved-save>Save</button>
      </div>
      <div id="unsaved-leave" data-unsaved-leave hidden>
        <button type="button" data-unsaved-stay>Keep editing</button>
        <button type="button" data-unsaved-confirm>Discard and leave</button>
      </div>
    </div>`
})

const type = (id, value) => {
  const input = document.querySelector(id)
  input.value = value
  input.dispatchEvent(new Event('input', {bubbles: true}))
}
const click = (id, options = {}) => {
  const event = new MouseEvent('click', {bubbles: true, cancelable: true, ...options})
  document.querySelector(id).dispatchEvent(event)
  return {defaultPrevented: !event.followed}
}
const unload = () => {
  const event = new Event('beforeunload', {cancelable: true})
  window.dispatchEvent(event)
  return event
}
const bar = () => document.querySelector('#unsaved-bar')
const asking = () => !document.querySelector('#unsaved-leave').hidden

test('typing shows the bar; ignored regions and the bar itself do not', () => {
  const {hook} = mountHook(UnsavedChanges, '#unsaved')
  expect(bar().hidden).toBe(true)
  type('#confirm', 'Acme')
  expect(hook.dirty).toBe(false)
  expect(bar().hidden).toBe(true)
  type('#name', 'Acme Labs')
  expect(hook.dirty).toBe(true)
  expect(bar().hidden).toBe(false)
  expect(hook.el.hasAttribute('data-dirty')).toBe(true)
  // Save is the form's own submit: nothing to ask about.
  expect(click('[data-unsaved-save]').defaultPrevented).toBe(false)
  expect(asking()).toBe(false)
})

test('a clean page leaves without asking', () => {
  mountHook(UnsavedChanges, '#unsaved')
  expect(click('#patch').defaultPrevented).toBe(false)
  expect(unload().defaultPrevented).toBe(false)
  expect(asking()).toBe(false)
})

test('a patch link asks first; Keep editing stays, with the changes and focus back', () => {
  const {hook, events} = mountHook(UnsavedChanges, '#unsaved')
  type('#name', 'Draft')
  const event = click('#patch')
  expect(event.defaultPrevented).toBe(true)
  expect(asking()).toBe(true)
  expect(document.activeElement.textContent).toBe('Keep editing')
  // A second click while the question is open is not asked twice.
  expect(click('#navigate').defaultPrevented).toBe(false)
  document.querySelector('[data-unsaved-stay]').click()
  expect(asking()).toBe(false)
  expect(hook.dirty).toBe(true)
  expect(document.querySelector('#name').value).toBe('Draft')
  expect(document.activeElement.id).toBe('patch')
  expect(events).toEqual([])
})

test('Discard and leave resets, tells the server, and follows the link', () => {
  const {hook, events} = mountHook(UnsavedChanges, '#unsaved')
  type('#name', 'Draft')
  type('#secret', 'never keep this')
  let followed = 0
  document.querySelector('#navigate').addEventListener('click', event => { if (!event.defaultPrevented) followed++ })
  click('#navigate')
  expect(followed).toBe(0)
  // The click that follows is the hook's own `link.click()`.
  document.querySelector('[data-unsaved-confirm]').click()
  expect(asking()).toBe(false)
  expect(hook.dirty).toBe(false)
  expect(document.querySelector('#name').value).toBe('Acme')
  expect(document.querySelector('#secret').value).toBe('')
  expect(events).toEqual([{name: 'discard-general', payload: {}, target: '3'}])
  expect(followed).toBe(1)
})

test('Escape keeps editing; other links and data-leaves-page ask; new tabs and anchors do not', () => {
  const {hook} = mountHook(UnsavedChanges, '#unsaved')
  type('#name', 'Draft')
  click('#plain')
  expect(asking()).toBe(true)
  expect(key(window, 'Escape').defaultPrevented).toBe(true)
  expect(asking()).toBe(false)
  expect(key(window, 'Escape').defaultPrevented).toBe(false)
  let hidden = 0
  document.querySelector('#menu-popover').hidePopover = () => hidden++
  expect(click('#switch').defaultPrevented).toBe(true)
  expect(hidden).toBe(1)
  document.querySelector('[data-unsaved-stay]').click()
  expect(click('#hash').defaultPrevented).toBe(false)
  expect(click('#blank').defaultPrevented).toBe(false)
  expect(click('#patch', {metaKey: true}).defaultPrevented).toBe(false)
  expect(click('#menu').defaultPrevented).toBe(false)
  expect(asking()).toBe(false)
  expect(hook.dirty).toBe(true)
})

test('closing or reloading the tab asks the browser while dirty', () => {
  const {hook} = mountHook(UnsavedChanges, '#unsaved')
  type('#name', 'Draft')
  expect(unload().defaultPrevented).toBe(true)
  hook.destroyed()
  expect(unload().defaultPrevented).toBe(false)
  expect(click('#patch').defaultPrevented).toBe(false)
})

test('the bar’s Discard resets and pushes to the page when it names no component', () => {
  const {hook, events} = mountHook(UnsavedChanges, '#unsaved')
  delete hook.el.dataset.discardTarget
  type('#name', 'Draft')
  document.querySelector('[data-unsaved-discard]').click()
  expect(hook.dirty).toBe(false)
  expect(bar().hidden).toBe(true)
  expect(document.querySelector('#name').value).toBe('Acme')
  expect(events).toEqual([{name: 'discard-general', payload: {}}])
})

test('a save the server confirms, a form reset, or another hook makes it clean', () => {
  const {hook} = mountHook(UnsavedChanges, '#unsaved')
  type('#name', 'Draft')
  // A patch that is not a save keeps the bar, which the render had hidden.
  bar().hidden = true
  hook.el.removeAttribute('data-dirty')
  hook.updated()
  expect(bar().hidden).toBe(false)
  expect(hook.el.hasAttribute('data-dirty')).toBe(true)
  hook.el.dataset.saved = '1'
  hook.updated()
  expect(hook.dirty).toBe(false)
  expect(bar().hidden).toBe(true)

  hook.el.dispatchEvent(new CustomEvent('unsaved:dirty', {bubbles: true}))
  expect(hook.dirty).toBe(true)
  hook.el.dispatchEvent(new CustomEvent('unsaved:clean', {bubbles: true}))
  expect(hook.dirty).toBe(false)

  type('#name', 'Draft')
  document.querySelector('#general').reset()
  expect(hook.dirty).toBe(false)
  type('#name', 'Draft')
  document.querySelector('[data-unsaved-ignore] form').reset()
  expect(hook.dirty).toBe(true)
})

test('a page without the bar still asks before leaving', () => {
  bar().remove()
  const {hook} = mountHook(UnsavedChanges, '#unsaved')
  type('#name', 'Draft')
  hook.updated()
  expect(click('#patch').defaultPrevented).toBe(true)
  expect(asking()).toBe(true)
})
