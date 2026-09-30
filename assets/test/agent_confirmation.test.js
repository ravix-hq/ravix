import {test, expect} from 'bun:test'
import {mountHook, key} from './setup.js'
import {AgentConfirmation} from '../js/hooks/agent_confirmation.js'

test('removal confirmation keeps focus until a decision, then restores the trigger', () => {
  document.body.innerHTML = '<div id="panel"><button id="remove-codex-api_key">Remove</button></div><button id="outside">Close</button>'
  const {hook} = mountHook(AgentConfirmation, '#panel')
  document.querySelector('#remove-codex-api_key').click()
  expect(key(window, 'Escape').defaultPrevented).toBe(false)
  hook.updated()
  hook.el.insertAdjacentHTML('beforeend', '<div id="agent-disconnect-confirmation"><button id="confirm-agent-disconnect">Remove connection</button><button id="cancel">Cancel</button></div>')
  hook.updated()
  expect(key(window, 'x').defaultPrevented).toBe(false)
  expect(key(window, 'Escape').defaultPrevented).toBe(true)
  expect(document.activeElement.id).toBe('confirm-agent-disconnect')
  const outside = new MouseEvent('click', {bubbles: true, cancelable: true})
  document.querySelector('#outside').dispatchEvent(outside)
  expect(outside.defaultPrevented).toBe(true)
  const inside = new MouseEvent('click', {bubbles: true, cancelable: true})
  document.querySelector('#cancel').dispatchEvent(inside)
  expect(inside.defaultPrevented).toBe(false)
  document.querySelector('#agent-disconnect-confirmation').remove()
  hook.updated()
  expect(document.activeElement.id).toBe('remove-codex-api_key')
})

test('a removed trigger does not break focus restoration and teardown releases listeners', () => {
  document.body.innerHTML = '<div id="panel"><div id="agent-disconnect-confirmation"></div></div>'
  const {hook} = mountHook(AgentConfirmation, '#panel')
  hook.updated()
  expect(key(window, 'Escape').defaultPrevented).toBe(true)
  document.querySelector('#agent-disconnect-confirmation').remove()
  hook.updated()
  hook.destroyed()
  expect(key(window, 'Escape').defaultPrevented).toBe(false)
})

test('a Remove from a closed card menu gives focus back to the menu button (RAV-77)', () => {
  document.body.innerHTML = `<div id="panel"><button id="agent-menu-codex-trigger" popovertarget="agent-menu-codex-menu">More</button>
    <div id="agent-menu-codex-menu" popover><button id="remove-codex-api_key">Remove</button></div></div>`
  const {hook} = mountHook(AgentConfirmation, '#panel')
  document.querySelector('#remove-codex-api_key').click()
  hook.el.insertAdjacentHTML('beforeend', '<div id="agent-disconnect-confirmation"><button id="confirm-agent-disconnect">Remove connection</button></div>')
  hook.updated()
  document.querySelector('#agent-disconnect-confirmation').remove()
  hook.updated()
  expect(document.activeElement.id).toBe('agent-menu-codex-trigger')
})
