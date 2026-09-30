import {beforeEach, expect, test} from 'bun:test'
import {ProjectTree} from '../js/hooks/project_tree.js'
import {QuickJump} from '../js/hooks/quick_jump.js'
import {mountHook} from './setup.js'

beforeEach(() => { localStorage.clear(); document.body.innerHTML = '' })
const tree = viewer => {
  document.body.innerHTML = `<div id="tree" data-viewer="${viewer}"><button data-collapse="p1" aria-expanded="true" aria-controls="tracks">Tracks</button><nav id="tracks"><a>Work</a></nav></div>`
  return mountHook(ProjectTree, '#tree').hook
}
test('collapse survives patches and reloads, scoped to the viewer', () => {
  let hook = tree('one')
  document.querySelector('button').click()
  expect(document.querySelector('nav').hidden).toBe(true)
  document.querySelector('nav').hidden = false
  hook.updated()
  expect(document.querySelector('nav').hidden).toBe(true)
  hook.destroyed()
  hook = tree('one')
  expect(document.querySelector('button').getAttribute('aria-expanded')).toBe('false')
  document.querySelector('button').click()
  expect(document.querySelector('nav').hidden).toBe(false)
  document.querySelector('button').click()
  hook.destroyed()
  tree('two').destroyed()
  expect(document.querySelector('nav').hidden).toBe(false)
})
test('invalid or unavailable storage never prevents navigation', () => {
  localStorage.setItem('ravix.project-tree.one', 'broken')
  let hook = tree('one')
  document.querySelector('a').click()
  document.querySelector('button').setAttribute('aria-controls', 'missing')
  hook.updated()
  hook.destroyed()
  const get = Storage.prototype.getItem, set = Storage.prototype.setItem
  Storage.prototype.getItem = () => { throw new Error('blocked') }
  Storage.prototype.setItem = () => { throw new Error('blocked') }
  try {
    hook = tree('one')
    document.querySelector('button').click()
    expect(document.querySelector('nav').hidden).toBe(true)
    hook.destroyed()
  } finally { Storage.prototype.getItem = get; Storage.prototype.setItem = set }
})
// RAV-96: the open track is kept in view, once per track it opens.
const rail = (open, {collapsed = false} = {}) => {
  document.body.innerHTML = `<div class="yard-scroll"><div id="tree" data-viewer="one">
    <button data-collapse="p1" aria-expanded="true" aria-controls="tracks-p1">P1</button>
    <nav id="tracks-p1"><a id="a" class="track-tab">A</a><a id="b" class="track-tab">B</a></nav>
    <button data-collapse="p2" aria-expanded="true" aria-controls="tracks-p2">P2</button>
    <nav id="tracks-p2"><a id="c" class="track-tab">C</a></nav></div></div>`
  if (open) document.getElementById(open).setAttribute('aria-current', 'page')
  if (collapsed) localStorage.setItem('ravix.project-tree.one', JSON.stringify({p2: true}))
  const scroller = document.querySelector('.yard-scroll')
  scroller.scrollTop = 100
  // The rail shows 0–300 on screen; each row sits at its own y.
  const at = {a: 40, b: 150, c: 600}
  scroller.getBoundingClientRect = () => ({top: 0, bottom: 300, height: 300})
  for (const [id, top] of Object.entries(at)) {
    document.getElementById(id).getBoundingClientRect = () => ({top, bottom: top + 28, height: 28})
  }
  return {scroller, at, hook: mountHook(ProjectTree, '#tree').hook}
}
const open = id => {
  document.querySelector('[aria-current="page"]')?.removeAttribute('aria-current')
  if (id) document.getElementById(id).setAttribute('aria-current', 'page')
}
test('the open track below the fold is scrolled just into view, and unfolded', () => {
  const {scroller} = rail('c', {collapsed: true})
  // Its project had been folded in this browser: it opens, and stays open.
  expect(document.getElementById('tracks-p2').hidden).toBe(false)
  expect(JSON.parse(localStorage.getItem('ravix.project-tree.one'))).toEqual({p2: false})
  // 600 + 28 - (300 - 8) further down, no more.
  expect(scroller.scrollTop).toBe(100 + 336)
})
test('a patch that keeps the same track open never moves the rail', () => {
  const {scroller, hook} = rail('c')
  scroller.scrollTop = 0
  hook.updated()
  expect(scroller.scrollTop).toBe(0)
  // Folding its own project by hand is respected too.
  document.querySelector('[data-collapse="p2"]').click()
  expect(document.getElementById('tracks-p2').hidden).toBe(true)
  hook.updated()
  expect(document.getElementById('tracks-p2').hidden).toBe(true)
})
test('a row above the fold scrolls up to it; one on screen stays put', () => {
  const {scroller, hook, at} = rail('b')
  expect(scroller.scrollTop).toBe(100)
  at.a = -50
  document.getElementById('a').getBoundingClientRect = () => ({top: -50, bottom: -22, height: 28})
  open('a'); hook.updated()
  expect(scroller.scrollTop).toBe(100 - 58)
  // No open track, or a closed drawer with nothing to measure: nothing moves.
  open(null); hook.updated()
  expect(scroller.scrollTop).toBe(42)
  scroller.getBoundingClientRect = () => ({top: 0, bottom: 0, height: 0})
  open('c'); hook.updated()
  expect(scroller.scrollTop).toBe(42)
})
test('a track outside a scroller, or still inside a fold, is not measured', () => {
  document.body.innerHTML = `<div id="tree" data-viewer="one"><nav id="n" hidden><a id="x" class="track-tab" aria-current="page">X</a></nav></div>`
  const {hook} = mountHook(ProjectTree, '#tree')
  hook.scrollTo(document.getElementById('x'))
  document.body.insertAdjacentHTML('beforeend', `<div class="yard-scroll"><div hidden><a id="y">Y</a></div></div>`)
  hook.scrollTo(document.getElementById('y'))
  expect(document.querySelector('.yard-scroll').scrollTop).toBe(0)
})
// RAV-96: a project's ⋯ menu behaves as a menu button. happy-dom has no
// popover API, so `showPopover` and the `toggle` event are stood in for.
const project = () => {
  document.body.innerHTML = `<div id="tree" data-viewer="one"><div class="workspace-project-row">
    <button id="more" aria-haspopup="menu" aria-expanded="false" popovertarget="menu">More</button>
    <div id="menu" class="project-menu" popover role="menu">
      <button id="people" role="menuitem" popovertarget="menu" popovertargetaction="hide">People</button>
      <button id="gone" role="menuitem" disabled>Gone</button>
      <button id="closed" role="menuitemcheckbox" aria-checked="false">Show closed tracks</button>
    </div></div></div>`
  const menu = document.getElementById('menu')
  menu.showPopover = () => toggle(menu, 'open')
  return {menu, more: document.getElementById('more'), hook: mountHook(ProjectTree, '#tree').hook}
}
const toggle = (el, state) => {
  const event = new Event('toggle')
  event.newState = state
  el.dispatchEvent(event)
}
test('the ⋯ menu says it is open, takes focus and gives it back', () => {
  const {menu, more, hook} = project()
  more.focus()
  key(more, 'Enter')
  expect(more.getAttribute('aria-expanded')).toBe('false')
  key(more, 'ArrowDown')
  expect(more.getAttribute('aria-expanded')).toBe('true')
  expect(document.activeElement.id).toBe('people')
  // A patch draws the trigger closed; the hook says it is still open.
  more.setAttribute('aria-expanded', 'false')
  hook.updated()
  expect(more.getAttribute('aria-expanded')).toBe('true')
  // Already open, the trigger's arrows leave it be.
  more.focus()
  expect(key(more, 'ArrowUp')).toBe(true)
  // Arrows skip the disabled item and wrap; Home and End go to the ends.
  document.getElementById('people').focus()
  key(document.activeElement, 'ArrowDown')
  expect(document.activeElement.id).toBe('closed')
  key(document.activeElement, 'ArrowDown')
  expect(document.activeElement.id).toBe('people')
  key(document.activeElement, 'ArrowUp')
  expect(document.activeElement.id).toBe('closed')
  key(document.activeElement, 'Home')
  expect(document.activeElement.id).toBe('people')
  key(document.activeElement, 'End')
  expect(document.activeElement.id).toBe('closed')
  expect(key(document.activeElement, 'x')).toBe(true)
  // Closing from inside returns focus to the trigger.
  toggle(menu, 'closed')
  expect(more.getAttribute('aria-expanded')).toBe('false')
  expect(document.activeElement).toBe(more)
  hook.destroyed()
})
test('closing the ⋯ menu by clicking elsewhere leaves focus there', () => {
  const {menu, more, hook} = project()
  document.body.insertAdjacentHTML('beforeend', '<input id="elsewhere">')
  toggle(menu, 'open')
  document.getElementById('elsewhere').focus()
  toggle(menu, 'closed')
  expect(document.activeElement.id).toBe('elsewhere')
  expect(more.getAttribute('aria-expanded')).toBe('false')
  // A toggle from any other popover, or a menu with nothing to focus, is not this hook's.
  document.getElementById('tree').insertAdjacentHTML('beforeend', '<div id="other" popover></div><div id="empty" class="project-menu" role="menu"></div>')
  toggle(document.getElementById('other'), 'open')
  toggle(document.getElementById('empty'), 'open')
  const empty = document.getElementById('empty')
  expect(key(empty, 'ArrowDown')).toBe(true)
  // A trigger whose menu is gone does nothing.
  menu.remove()
  expect(key(more, 'ArrowDown')).toBe(true)
  hook.destroyed()
})
const key = (target, value, options = {}) => target.dispatchEvent(new KeyboardEvent('keydown', {key: value, bubbles: true, cancelable: true, ...options}))
test('quick-jump chooses the visible trigger, arrows wrap and Enter opens the first result', () => {
  document.body.innerHTML = `<div id="workspace"><button data-quick-jump-trigger id="desktop">Search</button><button data-quick-jump-trigger id="mobile">Search</button></div>`
  const mobile = document.querySelector('#mobile')
  document.querySelector('#desktop').getClientRects = () => []
  mobile.getClientRects = () => [{}]
  let opened = 0
  mobile.onclick = () => { opened++ }
  const {hook} = mountHook(QuickJump, '#workspace')
  key(window, 'K', {ctrlKey: true})
  key(window, 'k', {ctrlKey: true})
  expect(opened).toBe(2)
  document.querySelector('#workspace').insertAdjacentHTML('beforeend', `<div id="search-dialog" class="scrim"><div role="dialog"><input id="search-query"><a href="#a" data-jump-result>A</a><a href="#b" data-jump-result>B</a></div></div>`)
  key(window, 'k', {ctrlKey: true})
  expect(opened).toBe(2)
  const input = document.querySelector('input'), [a,b] = document.querySelectorAll('a')
  input.focus(); key(input, 'ArrowDown'); expect(document.activeElement).toBe(a)
  key(a, 'ArrowUp'); expect(document.activeElement).toBe(b)
  key(b, 'ArrowDown'); expect(document.activeElement).toBe(a)
  input.focus(); key(input, 'ArrowUp'); expect(document.activeElement).toBe(b)
  let selected = 0; a.onclick = event => { event.preventDefault(); selected++ }
  input.focus(); key(input, 'Enter'); expect(selected).toBe(1)
  key(input, 'x'); key(mobile, 'ArrowDown')
  a.remove(); b.remove(); key(input, 'ArrowDown')
  hook.destroyed()
  document.querySelector('#search-dialog').remove()
  key(window, 'k', {ctrlKey: true}); expect(opened).toBe(2)
})

test('quick-jump keeps selected result focus when filtering moves its row', () => {
  document.body.innerHTML = `<div id="workspace"><input id="search-query"><a id="result" data-jump-result href="#project">Project</a></div>`
  const {hook} = mountHook(QuickJump, '#workspace')
  const input = document.querySelector('input'), link = document.querySelector('a')
  link.focus(); hook.beforeUpdate()
  link.remove(); document.querySelector('#workspace').append(link)
  hook.updated(); expect(document.activeElement).toBe(link)
  hook.beforeUpdate(); input.focus(); hook.updated(); expect(document.activeElement).toBe(input)
  hook.beforeUpdate(); hook.updated(); expect(document.activeElement).toBe(input)
  link.focus(); hook.beforeUpdate(); link.remove(); hook.updated()
  expect(document.activeElement).toBe(document.body)
})

test('quick-jump keys also move through a data-jump-scope list, skipping disabled results', () => {
  document.body.innerHTML = `<div id="workspace"><div id="repo-picker" data-jump-scope>
    <input id="repo-picker-query" data-jump-query>
    <button id="a" data-jump-result>acme/api</button>
    <button id="off" data-jump-result disabled>acme/busy</button>
    <button id="b" data-jump-result>acme/web</button>
  </div><input id="elsewhere"></div>`
  const {hook} = mountHook(QuickJump, '#workspace')
  const query = document.querySelector('#repo-picker-query')
  let picked = null
  document.querySelector('#a').addEventListener('click', () => { picked = 'a' })
  query.focus()
  expect(key(query, 'ArrowDown')).toBe(false)
  expect(document.activeElement.id).toBe('a')
  key(document.activeElement, 'ArrowDown')
  expect(document.activeElement.id).toBe('b')
  key(document.activeElement, 'ArrowDown')
  expect(document.activeElement.id).toBe('a')
  key(document.activeElement, 'ArrowUp')
  expect(document.activeElement.id).toBe('b')
  expect(key(query, 'Enter')).toBe(false)
  expect(picked).toBe('a')
  // Outside any scope the keys are left alone.
  const elsewhere = document.querySelector('#elsewhere')
  expect(key(elsewhere, 'ArrowDown')).toBe(true)
  hook.destroyed()
})
