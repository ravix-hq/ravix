import {beforeEach, expect, test} from 'bun:test'
import {ThreadTabs} from '../js/hooks/thread_tabs.js'
import {dimensions, key as press, mountHook} from './setup.js'

beforeEach(() => { document.body.innerHTML = `<nav id="threads"><div role="tablist"><button id="one" class="thread-tab" role="tab" aria-selected="false" tabindex="-1">One</button><button id="two" class="thread-tab" role="tab" aria-selected="true" tabindex="0">Two</button></div><button class="thread-add">Add</button></nav>` })
const key = (el, key, extra = {}) => el.dispatchEvent(new KeyboardEvent('keydown', {key, bubbles: true, cancelable: true, ...extra}))
test('roving focus wraps, Home/End work, and activation stays native', () => {
  const tabs = [...document.querySelectorAll('.thread-tab')]
  tabs.forEach(tab => { tab.scrollIntoView = () => {} })
  const {hook} = mountHook(ThreadTabs, '#threads')
  tabs[0].focus()
  key(tabs[0], 'ArrowLeft')
  expect(document.activeElement).toBe(tabs[1])
  expect(tabs.map(tab => tab.tabIndex)).toEqual([-1, 0])
  key(tabs[1], 'ArrowRight')
  expect(document.activeElement).toBe(tabs[0])
  expect(tabs.map(tab => tab.tabIndex)).toEqual([0, -1])
  key(tabs[0], 'End')
  expect(document.activeElement).toBe(tabs[1])
  key(tabs[1], 'Home')
  expect(document.activeElement).toBe(tabs[0])
  hook.updated()
  expect(tabs.map(tab => tab.tabIndex)).toEqual([0, -1])
  expect(key(tabs[0], 'Enter')).toBe(true)
  key(tabs[0], 'End', {ctrlKey: true})
  expect(document.activeElement).toBe(tabs[0])
  const add = document.querySelector('.thread-add')
  add.focus()
  key(add, 'Home')
  expect(document.activeElement).toBe(add)
  hook.destroyed()
  tabs[0].focus()
  key(tabs[0], 'End')
  expect(document.activeElement).toBe(tabs[0])
})
test('only a changed selection scrolls; activity patches preserve manual overflow position', () => {
  const tabs = [...document.querySelectorAll('.thread-tab')]
  const scrolled = []
  tabs.forEach(tab => { tab.scrollIntoView = () => scrolled.push(tab.id) })
  const {hook} = mountHook(ThreadTabs, '#threads')
  expect(scrolled).toEqual(['two'])
  hook.el.scrollLeft = 123
  tabs[0].textContent = 'One · Running (unread)'
  hook.updated()
  expect(scrolled).toEqual(['two'])
  expect(hook.el.scrollLeft).toBe(123)
  tabs[1].setAttribute('aria-selected', 'false')
  tabs[0].setAttribute('aria-selected', 'true')
  hook.updated()
  expect(scrolled).toEqual(['two', 'one'])
  expect(tabs.map(tab => tab.tabIndex)).toEqual([0, -1])
  tabs[0].remove()
  hook.updated()
  expect(scrolled).toEqual(['two', 'one'])
})

const strip = (attrs = 'data-can-rename') => {
  document.body.innerHTML = `<nav id="threads" ${attrs}><div class="thread-tablist" role="tablist"><button id="thread-tab-a" data-thread-id="a" class="thread-tab" role="tab" aria-selected="true" tabindex="0"><span>A</span></button><button id="thread-tab-draft" data-thread-id="draft" class="thread-tab" role="tab" aria-selected="false" tabindex="-1">New</button></div></nav>`
  document.querySelectorAll('.thread-tab').forEach(tab => { tab.scrollIntoView = () => {} })
}
const renaming = (hook, id) => {
  hook.el.dataset.renaming = id
  hook.el.insertAdjacentHTML('beforeend', `<form id="thread-rename-form" data-thread-id="${id}"><input id="thread-rename-input" value="A"></form>`)
  hook.updated()
  return document.getElementById('thread-rename-input')
}
const renamed = hook => {
  delete hook.el.dataset.renaming
  document.getElementById('thread-rename-form').remove()
  hook.updated()
}

test('RAV-97: the strip says which ends of the tablist overflow', () => {
  strip()
  const list = document.querySelector('.thread-tablist')
  dimensions(list, {clientWidth: 200, scrollWidth: 200})
  const {hook} = mountHook(ThreadTabs, '#threads')
  expect(hook.el.hasAttribute('data-overflow')).toBe(false)
  dimensions(list, {scrollWidth: 500})
  list.scrollLeft = 0
  list.dispatchEvent(new Event('scroll'))
  expect(hook.el.getAttribute('data-overflow')).toBe('end')
  list.scrollLeft = 150
  list.dispatchEvent(new Event('scroll'))
  expect(hook.el.getAttribute('data-overflow')).toBe('start end')
  list.scrollLeft = 300
  hook.updated()
  expect(hook.el.getAttribute('data-overflow')).toBe('start')
})

test('RAV-97: a double-click or F2 asks to rename a thread, never the draft or without leave', () => {
  strip()
  const {hook, events} = mountHook(ThreadTabs, '#threads')
  const [tab, draft] = document.querySelectorAll('.thread-tab')
  tab.querySelector('span').dispatchEvent(new MouseEvent('dblclick', {bubbles: true}))
  expect(events).toEqual([{name: 'edit-thread-title', payload: {thread_id: 'a'}}])
  // The second click of a double-click can land beside a tab that moved.
  tab.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, detail: 1}))
  hook.el.querySelector('.thread-tablist').dispatchEvent(new MouseEvent('dblclick', {bubbles: true}))
  expect(events.length).toBe(2)
  tab.focus()
  press(tab, 'F2')
  expect(events.at(-1)).toEqual({name: 'edit-thread-title', payload: {thread_id: 'a'}})
  draft.dispatchEvent(new MouseEvent('dblclick', {bubbles: true}))
  press(draft, 'F2')
  expect(events.length).toBe(3)
  hook.el.removeAttribute('data-can-rename')
  tab.dispatchEvent(new MouseEvent('dblclick', {bubbles: true}))
  expect(events.length).toBe(3)
})

test('RAV-97: the rename field takes focus; leaving it saves, Escape cancels, and focus returns', () => {
  strip()
  const {hook, events} = mountHook(ThreadTabs, '#threads')
  const tab = document.getElementById('thread-tab-a')
  let input = renaming(hook, 'a')
  expect(document.activeElement).toBe(input)
  input.value = 'Renamed'
  input.blur()
  expect(events).toEqual([{name: 'rename-thread', payload: {thread_id: 'a', title: 'Renamed'}}])
  renamed(hook)
  expect(document.activeElement).toBe(tab)

  input = renaming(hook, 'a')
  expect(press(input, 'Escape').defaultPrevented).toBe(true)
  expect(events.at(-1)).toEqual({name: 'cancel-thread-rename', payload: {}})
  // Other keys in the field are the field's, not the tabs'.
  expect(press(input, 'Home').defaultPrevented).toBe(false)
  input.blur()
  expect(events.filter(e => e.name === 'rename-thread').length).toBe(1)
  renamed(hook)
  expect(document.activeElement).toBe(tab)
})

test('RAV-97: keeping the selected tab in sight scrolls the tablist and nothing else', () => {
  strip()
  const {hook} = mountHook(ThreadTabs, '#threads')
  const list = document.querySelector('.thread-tablist')
  const tab = document.getElementById('thread-tab-a')
  const rect = (left, right) => () => ({left, right, top: 0, bottom: 30, width: right - left, height: 30})
  let scrolled = false
  tab.scrollIntoView = () => { scrolled = true }
  list.getBoundingClientRect = rect(100, 300)
  list.scrollLeft = 50
  tab.getBoundingClientRect = rect(260, 340)
  hook.reveal()
  expect(list.scrollLeft).toBe(90)
  tab.getBoundingClientRect = rect(80, 160)
  hook.reveal()
  expect(list.scrollLeft).toBe(70)
  tab.getBoundingClientRect = rect(120, 200)
  hook.reveal()
  expect(list.scrollLeft).toBe(70)
  expect(scrolled).toBe(false)
})
