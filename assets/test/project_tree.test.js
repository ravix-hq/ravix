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
