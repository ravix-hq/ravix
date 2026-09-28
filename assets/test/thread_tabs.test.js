import {beforeEach, expect, test} from 'bun:test'
import {ThreadTabs} from '../js/hooks/thread_tabs.js'
import {mountHook} from './setup.js'

beforeEach(() => { document.body.innerHTML = `<nav id="threads"><button class="thread-tab">One</button><button class="thread-tab" aria-current="true">Two</button><button class="thread-add">Add</button></nav>` })
const key = (el, key, extra = {}) => el.dispatchEvent(new KeyboardEvent('keydown', {key, bubbles: true, cancelable: true, ...extra}))
test('arrows wrap, Home/End focus threads, and activation stays native', () => {
  const tabs = [...document.querySelectorAll('.thread-tab')]
  const scrolled = []
  tabs.forEach(tab => { tab.scrollIntoView = () => scrolled.push(tab.textContent) })
  const {hook} = mountHook(ThreadTabs, '#threads')
  expect(scrolled).toEqual(['Two'])
  tabs[0].focus()
  key(tabs[0], 'ArrowLeft')
  expect(document.activeElement).toBe(tabs[1])
  key(tabs[1], 'ArrowRight')
  expect(document.activeElement).toBe(tabs[0])
  key(tabs[0], 'End')
  expect(document.activeElement).toBe(tabs[1])
  key(tabs[1], 'Home')
  expect(document.activeElement).toBe(tabs[0])
  expect(key(tabs[0], 'Enter')).toBe(true)
  key(tabs[0], 'End', {ctrlKey: true})
  expect(document.activeElement).toBe(tabs[0])
  const add = document.querySelector('.thread-add')
  add.focus()
  key(add, 'Home')
  expect(document.activeElement).toBe(add)
  tabs[1].removeAttribute('aria-current')
  hook.updated()
  hook.destroyed()
  tabs[0].focus()
  key(tabs[0], 'End')
  expect(document.activeElement).toBe(tabs[0])
})
