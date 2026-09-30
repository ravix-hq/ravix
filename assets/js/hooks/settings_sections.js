// A project settings section's own Save, Discard and agent choice. The URL
// says which section shows (data-section); leaving one with changes in it is
// asked about by UnsavedChanges, which this tells when it is dirty or clean.
// Keep only a dirty boolean; never copy secret values.
const DEFAULT_FEEDBACK = 'Each section saves separately.'

export const SettingsSections = {
  mounted() {
    this.section = this.el.dataset.section
    this.dirty = false
    this.version = this.el.dataset.saveVersion
    this.onInput = event => {
      if (!event.target.closest('form') || this.section === 'danger' ||
          event.target.closest('[id^=settings-connect-]')) return
      this.markDirty()
      if (event.target.id === 'settings-runtime') this.models(event.target.value)
    }
    this.onClick = event => {
      if (event.target.closest('[data-env-row-action]')) this.markDirty()
      const agent = event.target.closest('[data-settings-agent]')
      if (agent && !agent.disabled && agent.getAttribute('aria-pressed') !== 'true') this.markDirty()
      if (event.target.closest('[data-settings-discard]')) {
        if (this.el.dataset.saveState !== 'saving') this.discard()
        return
      }
      const secret = event.target.closest('[data-secret-action]')
      if (secret) {
        this.el.querySelector('#secret-store').value = secret.dataset.secretStore
        this.el.querySelector('#secret-key').value = secret.dataset.secretKey
        this.el.querySelector('#secret-value').value = ''
        this.el.querySelector('#secret-value').focus()
        this.markDirty()
        this.feedback(secret.dataset.secretAction === 'remove'
          ? 'Submit Update secret with an empty value to remove this key.'
          : 'Enter a replacement value, then submit Update secret.')
      }
    }
    this.el.addEventListener('input', this.onInput)
    this.el.addEventListener('click', this.onClick)
    this.show()
  },
  updated() {
    const wasConfirming = this.confirmingSwitch
    this.confirmingSwitch = !!this.el.querySelector('#agent-switch-confirmation')
    if (this.section !== this.el.dataset.section) {
      // Only a confirmed "Discard and leave" moves a dirty section on, and
      // the server still holds an agent choice or variable rows from it.
      if (this.dirty && this.el.dataset.component && ['agent', 'variables'].includes(this.section)) {
        this.pushEventTo(this.el.dataset.component, `discard-${this.section === 'agent' ? 'agent' : 'env-vars'}`, {})
      }
      this.section = this.el.dataset.section
      this.dirty = false
      this.feedback(DEFAULT_FEEDBACK)
    }
    if (this.version !== this.el.dataset.saveVersion) {
      this.version = this.el.dataset.saveVersion
      this.dirty = false
      const secret = this.el.querySelector('#secret-value')
      if (secret) secret.value = ''
    }
    if (this.el.dataset.saveState === 'error' && this.section === 'secrets') {
      this.el.querySelector('#secret-value').value = ''
    }
    this.show()
    if (wasConfirming && !this.confirmingSwitch && this.el.dataset.saveState !== 'saving') {
      this.el.querySelector('[data-switch-agent]')?.focus()
    }
    if (this.dirty && !this.el.dataset.saveState) this.feedback('Unsaved changes')
  },
  markDirty() {
    this.dirty = true
    this.show()
    this.feedback('Unsaved changes')
    this.el.dispatchEvent(new CustomEvent('unsaved:dirty', {bubbles: true}))
  },
  discard() {
    const panel = this.el.querySelector(`[data-settings-panel="${this.section}"]`)
    panel.querySelectorAll('form').forEach(form => form.reset())
    panel.querySelectorAll('input[type="password"]').forEach(input => { input.value = '' })
    if (this.section === 'variables' && this.el.dataset.component) {
      this.pushEventTo(this.el.dataset.component, 'discard-env-vars', {})
    }
    if (this.section === 'agent') {
      if (this.el.dataset.component) this.pushEventTo(this.el.dataset.component, 'discard-agent', {})
      this.models(this.el.querySelector('#settings-runtime').value, this.el.dataset.savedModel)
    }
    this.dirty = false
    this.show()
    this.feedback('Changes discarded.')
    this.el.dispatchEvent(new CustomEvent('unsaved:clean', {bubbles: true}))
    panel.querySelector('input, select, textarea, button')?.focus()
  },
  feedback(text) {
    this.el.querySelector('[data-settings-feedback]').textContent = text
  },
  show() {
    const runtime = this.el.querySelector('#settings-runtime')
    const switching = this.el.dataset.defaultOnly !== 'true' && runtime?.value !== this.el.dataset.savedRuntime
    const save = this.el.querySelector('[data-save-agent]')
    const rebuild = this.el.querySelector('[data-switch-agent]')
    if (save) save.hidden = switching
    if (rebuild) rebuild.hidden = !switching

    const discard = this.el.querySelector('[data-settings-discard]')
    discard.hidden = !this.dirty
    discard.disabled = this.el.dataset.saveState === 'saving' || !!this.el.querySelector('#agent-switch-confirmation')
  },
  models(runtime, selected) {
    const select = this.el.querySelector('#settings-model')
    const models = JSON.parse(this.el.dataset.models)[runtime] || []
    const labels = JSON.parse(this.el.dataset.modelLabels)
    select.replaceChildren(...models.map(value => {
      const option = document.createElement('option')
      option.value = value
      option.selected = value === selected
      option.textContent = labels[value]
      return option
    }))
  },
  destroyed() {
    this.el.removeEventListener('input', this.onInput)
    this.el.removeEventListener('click', this.onClick)
  },
}
