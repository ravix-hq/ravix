import {beforeEach, expect, test} from 'bun:test'
import {ThreadTabs} from '../js/hooks/thread_tabs.js'
import {mountHook} from './setup.js'

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
