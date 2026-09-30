import {afterEach, beforeEach, expect, test} from 'bun:test'
import {SettingsSections} from '../js/hooks/settings_sections.js'
import {mountHook} from './setup.js'

// A link's default action would load a page in happy-dom; whether anything
// prevented it is noted first.
const follow = event => { event.followed = !event.defaultPrevented; event.preventDefault() }
beforeEach(() => window.addEventListener('click', follow))
afterEach(() => window.removeEventListener('click', follow))

// One project settings page: the URL's section (data-section) shows, the
// others are hidden by the server. Leaving is UnsavedChanges' business;
// this hook only tells it, with `unsaved:dirty` and `unsaved:clean`.
beforeEach(() => {
  document.body.innerHTML = `<div id="scope">
    <div id="settings" data-section="general" data-model-labels='{"model-a":"Model A","model-b":"Model B"}' data-saved-runtime="claude" data-save-version="0" data-save-state="" data-models='{"claude":["model-a","model-b"]}'>
    <p data-settings-feedback></p><button data-settings-discard hidden>Discard changes</button>
    <section data-settings-panel="general"><form><input id="name" value="Original"><input id="secret-value" type="password"><button class="primary">Save general</button></form></section>
    <section data-settings-panel="agent" hidden><form><select id="settings-runtime"><option selected>claude</option><option>codex</option></select><select id="settings-model"></select><button data-save-agent class="primary">Save agent</button><button data-switch-agent class="primary" hidden>Switch and rebuild</button></form></section>
    <section data-settings-panel="danger" hidden><form><input id="confirm"></form></section>
    </div></div><a id="outside" href="/elsewhere">Outside</a>`
})

const edit = id => document.querySelector(id).dispatchEvent(new Event('input', {bubbles: true}))
const told = () => {
  const said = []
  document.querySelector('#scope').addEventListener('unsaved:dirty', () => said.push('dirty'))
  document.querySelector('#scope').addEventListener('unsaved:clean', () => said.push('clean'))
  return said
}

test('input marks the section dirty, says so, and tells UnsavedChanges; discard resets it', () => {
  const said = told()
  const {hook} = mountHook(SettingsSections, '#settings')
  expect(hook.section).toBe('general')
  document.querySelector('#name').value = 'Draft'
  edit('#name')
  expect(hook.dirty).toBe(true)
  expect(document.querySelector('[data-settings-feedback]').textContent).toBe('Unsaved changes')
  expect(document.querySelector('[data-settings-discard]').hidden).toBe(false)
  // Leaving is not blocked here any more: the click goes where it goes.
  const click = new MouseEvent('click', {bubbles: true, cancelable: true})
  document.querySelector('#outside').dispatchEvent(click)
  expect(click.followed).toBe(true)
  document.querySelector('[data-settings-discard]').click()
  expect(document.querySelector('#name').value).toBe('Original')
  expect(document.querySelector('[data-settings-discard]').hidden).toBe(true)
  expect(document.activeElement.id).toBe('name')
  expect(said).toEqual(['dirty', 'clean'])
})

test('the danger zone and an inline agent connection never count as unsaved', () => {
  const said = told()
  const {hook} = mountHook(SettingsSections, '#settings')
  hook.section = 'danger'
  edit('#confirm')
  expect(hook.dirty).toBe(false)
  hook.section = 'agent'
  document.querySelector('[data-settings-panel=agent]').insertAdjacentHTML('afterbegin', '<div id="settings-connect-codex"><form><input id="inline-key"></form></div>')
  edit('#inline-key')
  expect(hook.dirty).toBe(false)
  expect(said).toEqual([])
})

test('a successful save clears dirty state and the secret box; a failed secret save clears it too', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  edit('#secret-value')
  hook.el.dataset.saveState = 'saving'
  hook.updated()
  expect(document.querySelector('[data-settings-discard]').disabled).toBe(true)
  document.querySelector('[data-settings-discard]').click()
  expect(hook.dirty).toBe(true)
  hook.el.dataset.saveState = 'saved'
  hook.el.dataset.saveVersion = '1'
  document.querySelector('#secret-value').value = 'never keep this'
  hook.updated()
  expect(hook.dirty).toBe(false)
  expect(document.querySelector('#secret-value').value).toBe('')
  hook.el.dataset.section = 'secrets'
  hook.el.dataset.saveState = 'error'
  document.querySelector('#secret-value').value = 'sensitive'
  hook.updated()
  expect(document.querySelector('#secret-value').value).toBe('')
})

test('a new section from the URL starts clean; leaving a dirty agent section discards its server state', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  hook.el.dataset.component = '7'
  const calls = []
  hook.pushEventTo = (...args) => calls.push(args)
  hook.el.dataset.section = 'agent'
  hook.updated()
  expect(hook.section).toBe('agent')
  document.querySelector('#settings-runtime').value = 'codex'
  edit('#settings-runtime')
  hook.el.dataset.section = 'general'
  hook.updated()
  expect(hook.dirty).toBe(false)
  expect(calls).toEqual([['7', 'discard-agent', {}]])
  expect(document.querySelector('[data-settings-feedback]').textContent).toBe('Each section saves separately.')
  hook.el.dataset.section = 'agent'
  hook.updated()
  expect(calls.length).toBe(1)
})

test('unrelated patches keep the warning; unavailable models are empty', () => {
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
  expect(document.activeElement.id).toBe('secret-value')
  document.querySelector('[data-secret-action=remove]').click()
  expect(document.querySelector('[data-settings-feedback]').textContent).toContain('empty value')
  expect(hook.dirty).toBe(true)
  expect(events).toEqual([])
})

test('runtime changes and discarded edits use server model labels without changing ids', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  const labels = {'openai/gpt-5.5': 'GPT-5.5', 'anthropic/claude-fable-5-1': 'Claude Fable 5.1'}
  hook.el.dataset.models = JSON.stringify({claude: Object.keys(labels)})
  hook.el.dataset.modelLabels = JSON.stringify(labels)
  edit('#settings-runtime')
  expect([...document.querySelector('#settings-model').options].map(o => [o.value, o.textContent])).toEqual(Object.entries(labels))
  hook.section = 'agent'
  hook.el.dataset.savedModel = 'openai/gpt-5.5'
  document.querySelector('[data-settings-discard]').click()
  expect(document.querySelector('#settings-model').value).toBe('openai/gpt-5.5')
})

test('runtime switches expose the explicit rebuild action and discard restores Save agent', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  hook.section = 'agent'
  expect(document.querySelector('[data-switch-agent]').hidden).toBe(true)
  document.querySelector('#settings-runtime').value = 'codex'
  edit('#settings-runtime')
  expect(document.querySelector('[data-save-agent]').hidden).toBe(true)
  expect(document.querySelector('[data-switch-agent]').hidden).toBe(false)
  document.querySelector('[data-settings-discard]').click()
  expect(document.querySelector('[data-switch-agent]').hidden).toBe(true)
  expect(document.querySelector('[data-save-agent]').hidden).toBe(false)
})

test('the switch confirmation blocks discard, then returns focus to the switch on Cancel', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  hook.section = 'agent'
  document.querySelector('#settings-runtime').value = 'codex'
  edit('#settings-runtime')
  document.querySelector('[data-settings-panel=agent]').insertAdjacentHTML('beforeend', '<div id="agent-switch-confirmation"><button id="confirm-agent-switch">Rebuild and switch</button></div>')
  hook.updated()
  expect(document.querySelector('[data-settings-discard]').disabled).toBe(true)
  document.querySelector('#agent-switch-confirmation').remove()
  hook.updated()
  expect(document.querySelector('[data-settings-discard]').disabled).toBe(false)
  expect(document.activeElement).toBe(document.querySelector('[data-switch-agent]'))
})

test('the agent picker marks a changed selection and discards server state', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  hook.section = 'agent'
  hook.el.dataset.component = '7'
  const calls = []
  hook.pushEventTo = (...args) => calls.push(args)
  const panel = document.querySelector('[data-settings-panel=agent]')
  panel.insertAdjacentHTML('afterbegin', '<button data-settings-agent="claude" aria-pressed="true">Claude</button><button data-settings-agent="codex" aria-pressed="false">Codex</button>')
  document.querySelector('[data-settings-agent=claude]').click()
  expect(hook.dirty).toBe(false)
  document.querySelector('[data-settings-agent=codex]').click()
  expect(hook.dirty).toBe(true)
  document.querySelector('[data-settings-discard]').click()
  expect(calls).toEqual([['7', 'discard-agent', {}]])
  expect(hook.dirty).toBe(false)
})

test('variable row actions mark the section dirty and discard restores the server rows', () => {
  const {hook} = mountHook(SettingsSections, '#settings')
  hook.el.dataset.component = '7'
  hook.el.insertAdjacentHTML('beforeend', `<section data-settings-panel="variables"><form><button type="button" data-env-row-action>Add variable</button><button class="primary">Save variables</button></form></section>`)
  const calls = []
  hook.pushEventTo = (...args) => calls.push(args)
  hook.section = 'variables'
  document.querySelector('[data-env-row-action]').click()
  expect(hook.dirty).toBe(true)
  document.querySelector('[data-settings-discard]').click()
  expect(calls).toEqual([['7', 'discard-env-vars', {}]])
  expect(hook.dirty).toBe(false)
  hook.destroyed()
  document.querySelector('[data-env-row-action]').click()
  expect(hook.dirty).toBe(false)
})
