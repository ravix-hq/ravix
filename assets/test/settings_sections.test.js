import {beforeEach, expect, test} from 'bun:test'
import {SettingsSections} from '../js/hooks/settings_sections.js'
import {mountHook, key} from './setup.js'

beforeEach(() => {
  document.body.innerHTML = `<div class="dialog"><button aria-label="Close">Close</button>
    <div id="settings" data-model-labels='{"model-a":"Model A","model-b":"Model B"}' data-save-version="0" data-save-state="" data-models='{"claude":["model-a","model-b"]}'>
    <button data-settings-section="general">General</button><button data-settings-section="agent">Agent</button>
    <p data-settings-feedback></p>
    <section data-settings-panel="general"><h3 tabindex="-1">General</h3><form><input id="name" value="Original"><input id="secret-value" type="password"></form></section>
    <section data-settings-panel="agent" hidden><h3 tabindex="-1">Agent</h3><form><select id="settings-runtime"><option>claude</option></select><select id="settings-model"></select></form></section>
    </div></div><button id="outside">Outside</button>`
})

const edit = id => document.querySelector(id).dispatchEvent(new Event('input', {bubbles: true}))

test('navigation confirms dirty input, focuses heading, and resets discarded fields', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  document.querySelector('#name').value = 'Draft'
  edit('#name')
  expect(document.querySelector('[data-settings-feedback]').textContent).toBe('Unsaved changes')
  window.confirm = () => false
  document.querySelector('[data-settings-section=agent]').click()
  expect(hook.section).toBe('general')
  expect(key(window, 'Escape').defaultPrevented).toBe(true)
  const unload = new Event('beforeunload', {cancelable: true})
  window.dispatchEvent(unload)
  expect(unload.defaultPrevented).toBe(true)
  window.confirm = () => true
  document.querySelector('[data-settings-section=agent]').click()
  expect(hook.section).toBe('agent')
  expect(document.querySelector('#name').value).toBe('Original')
  expect(document.activeElement.textContent).toBe('Agent')
  expect(document.querySelector('[data-settings-panel=general]').hidden).toBe(true)
  edit('#settings-runtime')
  expect([...document.querySelector('#settings-model').options].map(o => o.value)).toEqual(['model-a', 'model-b'])
})

test('pending saves prevent leaving; success clears dirty state and secret input', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  edit('#secret-value')
  hook.el.dataset.saveState = 'saving'
  document.querySelector('[aria-label=Close]').click()
  expect(document.querySelector('[data-settings-feedback]').textContent).toContain('Wait')
  document.querySelector('#outside').click()
  expect(key(window, 'Escape').defaultPrevented).toBe(true)
  hook.el.dataset.saveState = 'saved'
  hook.el.dataset.saveVersion = '1'
  document.querySelector('#secret-value').value = 'never keep this'
  hook.updated()
  expect(hook.dirty).toBe(false)
  expect(document.querySelector('#secret-value').value).toBe('')
  expect(key(window, 'Escape').defaultPrevented).toBe(false)
  document.querySelector('[data-settings-section=general]').click()
  document.querySelector('#name').click()
  const unload = new Event('beforeunload', {cancelable: true})
  window.dispatchEvent(unload)
  expect(unload.defaultPrevented).toBe(false)
})

test('unrelated patches preserve navigation and dirty warning; unavailable models are empty', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  edit('#name')
  hook.updated()
  expect(hook.dirty).toBe(true)
  expect(document.querySelector('[data-settings-feedback]').textContent).toBe('Unsaved changes')
  hook.models('missing')
  expect(document.querySelector('#settings-model').options.length).toBe(0)
  document.querySelector('[data-settings-feedback]').dispatchEvent(new Event('input', {bubbles: true}))
})

test('existing secret actions choose the key and store without saving or retaining values', () => {
  const {hook, events} = mountHook(SettingsSections, '#settings')
  hook.el.insertAdjacentHTML('beforeend', `<select id="secret-store"><option>env</option><option>vault</option></select><input id="secret-key">
    <button data-secret-action="replace" data-secret-key="TOKEN" data-secret-store="vault">Replace</button>
    <button data-secret-action="remove" data-secret-key="TOKEN" data-secret-store="vault">Remove</button>`)
  document.querySelector('[data-secret-action=replace]').click()
  expect(document.querySelector('#secret-key').value).toBe('TOKEN')
  expect(document.querySelector('#secret-store').value).toBe('vault')
  expect(document.querySelector('[data-settings-feedback]').textContent).toContain('replacement')
  document.querySelector('[data-secret-action=remove]').click()
  expect(document.querySelector('[data-settings-feedback]').textContent).toContain('empty value')
  expect(events).toEqual([])
  hook.section = 'secrets'
  hook.el.dataset.saveState = 'error'
  document.querySelector('#secret-value').value = 'sensitive'
  hook.updated()
  expect(document.querySelector('#secret-value').value).toBe('')
})

test('runtime changes and discarded edits use server model labels without changing ids', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  const labels = {'openai/gpt-5.5': 'GPT-5.5', 'anthropic/claude-fable-5-1': 'Claude Fable 5.1'}
  hook.el.dataset.models = JSON.stringify({claude: Object.keys(labels)})
  hook.el.dataset.modelLabels = JSON.stringify(labels)
  edit('#settings-runtime')
  expect([...document.querySelector('#settings-model').options].map(o => [o.value, o.textContent])).toEqual(Object.entries(labels))
  hook.models('claude', 'openai/gpt-5.5')
  expect(document.querySelector('#settings-model').value).toBe('openai/gpt-5.5')
})
