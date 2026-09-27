import {beforeEach, expect, test} from 'bun:test'
import {TrackTabs} from '../js/hooks/track_tabs.js'
import {key, mountHook} from './setup.js'

let tabs, revealed
beforeEach(() => {
  document.body.innerHTML = `<nav id="tabs"><div role="tablist"><a role="tab" href="/one" aria-selected="true">One</a><a role="tab" href="/two" aria-selected="false">Two</a><a role="tab" href="/three" aria-selected="false">Three</a></div><button>New track</button></nav>`
  tabs = [...document.querySelectorAll('[role="tab"]')]
  revealed = 0
  for (const tab of tabs) tab.scrollIntoView = () => { revealed++ }
})

test('vertical arrows wrap, Home/End rove, and activation waits for Enter or Space', () => {
  mountHook(TrackTabs, '#tabs')
  tabs[0].focus()
  let clicks = 0
  tabs[2].addEventListener('click', event => { event.preventDefault(); clicks++ })
  key(tabs[0], 'ArrowUp')
  expect(document.activeElement).toBe(tabs[2])
  expect(tabs.map(tab => tab.tabIndex)).toEqual([-1, -1, 0])
  expect(clicks).toBe(0)
  key(tabs[2], 'ArrowDown')
  expect(document.activeElement).toBe(tabs[0])
  key(tabs[0], 'End')
  expect(document.activeElement).toBe(tabs[2])
  expect(key(tabs[2], ' ').defaultPrevented).toBe(true)
  expect(clicks).toBe(1)
  key(tabs[2], 'Home')
  expect(document.activeElement).toBe(tabs[0])
  for (const [name, options] of [['ArrowLeft', {}], ['Enter', {}], ['ArrowDown', {ctrlKey: true}], ['ArrowDown', {altKey: true}], ['ArrowDown', {metaKey: true}]]) {
    expect(key(tabs[0], name, options).defaultPrevented).toBe(false)
  }
})

test('patches retain roving focus and only reveal a changed selection', () => {
  const {hook} = mountHook(TrackTabs, '#tabs')
  expect(revealed).toBe(1)
  tabs[1].focus()
  tabs[1].tabIndex = -1
  hook.updated()
  expect(tabs[1].tabIndex).toBe(0)
  expect(revealed).toBe(1)
  tabs[0].setAttribute('aria-selected', 'false')
  tabs[2].setAttribute('aria-selected', 'true')
  tabs[1].blur()
  hook.updated()
  expect(revealed).toBe(2)
  expect(tabs.map(tab => tab.tabIndex)).toEqual([-1, -1, 0])
  tabs[2].setAttribute('aria-selected', 'false')
  hook.updated()
  expect(revealed).toBe(2)
  expect(tabs.every(tab => tab.tabIndex === -1)).toBe(true)
})

test('non-tab keys are ignored and listeners are removed on teardown', () => {
  const {hook} = mountHook(TrackTabs, '#tabs')
  expect(key(hook.strip, 'Home').defaultPrevented).toBe(false)
  hook.focus({target: hook.strip})
  hook.destroyed()
  tabs[0].focus()
  key(tabs[0], 'ArrowDown')
  expect(document.activeElement).toBe(tabs[0])
  expect(tabs[1].tabIndex).toBe(-1)
})
