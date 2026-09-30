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
