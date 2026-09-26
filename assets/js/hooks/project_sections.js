// Dragging a project onto a sidebar section files it there. A drag never
// round-trips while it is in flight, so only the drop reaches the server,
// which still checks that the project and section belong to this person.
const TYPE = 'application/x-ravix-project'

export const ProjectSections = {
  mounted() {
    this.dragged = null
    this.onStart = event => {
      const project = event.target.closest?.('[data-project-id][draggable="true"]')
      if (!project) return
      this.dragged = project
      project.classList.add('dragging')
      event.dataTransfer.effectAllowed = 'move'
      event.dataTransfer.setData(TYPE, project.dataset.projectId)
    }
    this.onOver = event => {
      const target = this.target(event)
      if (!target) return
      event.preventDefault()
      event.dataTransfer.dropEffect = 'move'
      this.highlight(target)
    }
    this.onLeave = event => {
      const target = this.target(event)
      if (target && !target.contains(event.relatedTarget)) target.classList.remove('drop-target')
    }
    this.onDrop = event => {
      const target = this.target(event)
      if (!target) return
      event.preventDefault()
      const project = this.dragged.dataset.projectId
      const from = this.dragged.closest('[data-section-drop]')
      this.finish()
      if (from === target) return
      this.pushEvent('move-project', {project, section: target.dataset.sectionDrop})
    }
    this.onEnd = () => this.finish()
    this.el.addEventListener('dragstart', this.onStart)
    this.el.addEventListener('dragover', this.onOver)
    this.el.addEventListener('dragleave', this.onLeave)
    this.el.addEventListener('drop', this.onDrop)
    this.el.addEventListener('dragend', this.onEnd)
  },
  // Only a project dragged from this sidebar has a section to land in.
  target(event) {
    if (!this.dragged) return null
    return event.target.closest?.('[data-section-drop]') ?? null
  },
  highlight(target) {
    this.el.querySelectorAll('.drop-target').forEach(el => el !== target && el.classList.remove('drop-target'))
    target.classList.add('drop-target')
  },
  finish() {
    this.dragged?.classList.remove('dragging')
    this.dragged = null
    this.el.querySelectorAll('.drop-target').forEach(el => el.classList.remove('drop-target'))
  },
  destroyed() {
    this.el.removeEventListener('dragstart', this.onStart)
    this.el.removeEventListener('dragover', this.onOver)
    this.el.removeEventListener('dragleave', this.onLeave)
    this.el.removeEventListener('drop', this.onDrop)
    this.el.removeEventListener('dragend', this.onEnd)
  },
}
