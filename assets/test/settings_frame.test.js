import {expect, test} from 'bun:test'
import {SettingsFrame} from '../js/hooks/settings_frame.js'
import {mountHook} from './setup.js'

test('a new section opens at the top; a patch within one keeps the scroll', () => {
  document.body.innerHTML = '<div id="page" data-section="general" style="height: 100px; overflow: auto"><div style="height: 1000px"></div></div>'
  const {hook} = mountHook(SettingsFrame, '#page')
  hook.el.scrollTop = 300
  hook.updated()
  expect(hook.el.scrollTop).toBe(300)
  hook.el.dataset.section = 'agent'
  hook.updated()
  expect(hook.el.scrollTop).toBe(0)
})

// RAV-74: an old section's URL lands on the page that holds it now, at the
// part it became (`/settings/machine#machine-secrets`).
test('a URL naming a part of the page opens at that part', () => {
  document.body.innerHTML = '<div id="page" data-section="general"><div id="machine-secrets"></div></div><div id="elsewhere"></div>'
  const seen = []
  document.getElementById('machine-secrets').scrollIntoView = () => seen.push('machine-secrets')
  document.getElementById('elsewhere').scrollIntoView = () => seen.push('elsewhere')
  window.location.hash = '#machine-secrets'
  const {hook} = mountHook(SettingsFrame, '#page')
  expect(seen).toEqual(['machine-secrets'])
  hook.el.dataset.section = 'machine'
  hook.updated()
  expect(seen).toEqual(['machine-secrets', 'machine-secrets'])
  // A fragment naming something outside the frame is not followed.
  window.location.hash = '#elsewhere'
  hook.el.scrollTop = 50
  hook.el.dataset.section = 'danger'
  hook.updated()
  expect(seen).toEqual(['machine-secrets', 'machine-secrets'])
  expect(hook.el.scrollTop).toBe(0)
  window.location.hash = ''
})

test('deep links and validation reveal fields inside collapsed advanced sections', () => {
  document.body.innerHTML = '<div id="page" data-section="machine"><details id="advanced"><summary>Advanced</summary><details id="nested"><summary>More</summary><input id="option" required><p id="error"></p></details></details></div>'
  const advanced = document.getElementById('advanced')
  const nested = document.getElementById('nested')
  const option = document.getElementById('option')
  option.scrollIntoView = () => {}
  window.location.hash = '#option'
  const {hook} = mountHook(SettingsFrame, '#page')
  expect(advanced.open && nested.open).toBe(true)

  advanced.open = nested.open = false
  option.dispatchEvent(new Event('invalid', {cancelable: true}))
  expect(advanced.open && nested.open).toBe(true)

  advanced.open = nested.open = false
  document.getElementById('error').className = 'error'
  document.getElementById('error').textContent = 'A value is required'
  hook.updated()
  expect(advanced.open && nested.open).toBe(true)
  window.location.hash = ''
})
