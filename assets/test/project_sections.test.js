import {beforeEach, expect, test} from 'bun:test'
import {ProjectSections} from '../js/hooks/project_sections.js'
import {mountHook} from './setup.js'

beforeEach(() => {
  document.body.innerHTML = `<div id="sections">
    <div id="section-other" data-section-drop="">
      <section id="alpha" data-project-id="p1" draggable="true"><a href="/p/p1">Alpha</a></section>
      <section id="fixed" data-project-id="p2" draggable="false"><a href="/p/p2">Fixed</a></section>
    </div>
    <div id="section-work" data-section-drop="s1"><span class="yard-label">Work</span><p id="empty">No projects</p></div>
  </div>`
})
const drag = (el, type, options = {}) => {
  const event = new Event(type, {bubbles: true, cancelable: true})
  const data = {}
  const transfer = {setData: (key, value) => { data[key] = value }, data}
  Object.defineProperties(event, {dataTransfer: {value: transfer}, relatedTarget: {value: options.relatedTarget ?? null}})
  el.dispatchEvent(event)
  return event
}
const $ = selector => document.querySelector(selector)

test('dropping a project on another section moves it there', () => {
  const {events} = mountHook(ProjectSections, '#sections')
  const start = drag($('#alpha a'), 'dragstart')
  expect(start.dataTransfer.data['application/x-ravix-project']).toBe('p1')
  expect(start.dataTransfer.effectAllowed).toBe('move')
  expect($('#alpha').classList.contains('dragging')).toBe(true)
  const over = drag($('#empty'), 'dragover')
  expect(over.defaultPrevented).toBe(true)
  expect($('#section-work').classList.contains('drop-target')).toBe(true)
  drag($('#section-other'), 'dragover')
  expect($('#section-work').classList.contains('drop-target')).toBe(false)
  drag($('#section-work'), 'dragover')
  expect(drag($('#section-work .yard-label'), 'drop').defaultPrevented).toBe(true)
  expect(events).toEqual([{name: 'move-project', payload: {project: 'p1', section: 's1'}}])
  expect(document.querySelectorAll('.dragging, .drop-target')).toHaveLength(0)
})

test('dropping back on the same section, back into Other projects, or cancelling', () => {
  const {events} = mountHook(ProjectSections, '#sections')
  drag($('#alpha'), 'dragstart')
  drag($('#section-other'), 'drop')
  expect(events).toEqual([])
  $('#section-work').append($('#alpha'))
  drag($('#alpha'), 'dragstart')
  drag($('#section-other'), 'drop')
  expect(events).toEqual([{name: 'move-project', payload: {project: 'p1', section: ''}}])
  drag($('#alpha'), 'dragstart')
  drag($('#section-other'), 'dragover')
  drag($('#section-other'), 'dragleave', {relatedTarget: $('#fixed')})
  expect($('#section-other').classList.contains('drop-target')).toBe(true)
  drag($('#section-other'), 'dragleave', {relatedTarget: $('#empty')})
  expect($('#section-other').classList.contains('drop-target')).toBe(false)
  drag($('#alpha'), 'dragend')
  expect($('#alpha').classList.contains('dragging')).toBe(false)
  expect(drag($('#section-other'), 'drop').defaultPrevented).toBe(false)
  expect(events).toHaveLength(1)
})

test('ignores foreign drags and projects that cannot move, and stops listening when destroyed', () => {
  const {hook, events} = mountHook(ProjectSections, '#sections')
  const start = drag($('#fixed a'), 'dragstart')
  expect(start.dataTransfer.data).toEqual({})
  expect(drag($('#section-work'), 'dragover').defaultPrevented).toBe(false)
  expect(drag($('#section-work'), 'drop').defaultPrevented).toBe(false)
  drag($('#section-work'), 'dragleave')
  hook.destroyed()
  drag($('#alpha'), 'dragstart')
  expect($('#alpha').classList.contains('dragging')).toBe(false)
  expect(events).toEqual([])
})
