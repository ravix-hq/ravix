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
  expect(document.activeElement).toBe(mobile)
  document.querySelector('#workspace').insertAdjacentHTML('beforeend', `<div id="search-dialog" role="dialog"><input id="search-query"><a href="#a" data-jump-result>A</a><a href="#b" data-jump-result>B</a></div>`)
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

for (const [platform, modifier, other] of [['MacIntel', 'metaKey', 'ctrlKey'], ['Linux x86_64', 'ctrlKey', 'metaKey']]) {
  test(`shortcut respects ${platform} and preserves editing shortcuts`, () => {
    Object.defineProperty(navigator, 'platform', {value: platform, configurable: true})
    document.body.innerHTML = `<div id="workspace"><button data-quick-jump-trigger>Search</button><textarea></textarea><input><select></select><div contenteditable="true"><span>Compose</span></div><div role="textbox"></div><div class="xterm"><span>Terminal</span></div></div>`
    const button = document.querySelector('button')
    button.getClientRects = () => [{}]
    let opened = 0
    button.onclick = () => opened++
    const {hook} = mountHook(QuickJump, '#workspace')
    expect(key(button, 'k', {[other]: true})).toBe(true)
    expect(opened).toBe(0)
    for (const target of document.querySelectorAll('textarea, input, select, [contenteditable] span, [role="textbox"], .xterm span')) {
      expect(key(target, 'k', {[modifier]: true})).toBe(true)
    }
    expect(opened).toBe(0)
    expect(key(button, 'k', {[modifier]: true})).toBe(false)
    expect(opened).toBe(1)
    hook.destroyed()
    Object.defineProperty(navigator, 'platform', {value: 'Linux x86_64', configurable: true})
  })
}
