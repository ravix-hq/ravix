// Settings navigation and loss-of-input warnings must run before LiveView's
// click/escape handlers. Keep only a dirty boolean; never copy secret values.
export const SettingsSections = {
  mounted() {
    this.section = 'general'
    this.dirty = false
    this.version = this.el.dataset.saveVersion
    this.onInput = event => {
      if (!event.target.closest('form') || this.section === 'danger' ||
          event.target.closest('[id^=settings-connect-]')) return
      this.dirty = true
      this.showSection()
      this.feedback('Unsaved changes')
      if (event.target.id === 'settings-runtime') this.models(event.target.value)
    }
    this.onClick = event => {
      const agent = event.target.closest('[data-settings-agent]')
      if (agent && !agent.disabled && agent.getAttribute('aria-pressed') !== 'true') {
        this.dirty = true
        this.feedback('Unsaved changes')
      }
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
        this.dirty = true
        this.showSection()
        this.feedback(secret.dataset.secretAction === 'remove'
          ? 'Submit Update secret with an empty value to remove this key.'
          : 'Enter a replacement value, then submit Update secret.')
        return
      }
      const tab = event.target.closest('[data-settings-section]')
      const inside = this.el.closest('.dialog').contains(event.target)
      const close = event.target.closest('[aria-label="Close"]')
      if (!tab && inside && !close) return
      if (tab?.dataset.settingsSection === this.section) return
      if (!this.mayLeave()) {
        event.preventDefault()
        event.stopImmediatePropagation()
        return
      }
      if (tab) {
        this.section = tab.dataset.settingsSection
        this.dirty = false
        this.showSection()
        this.el.querySelector(`[data-settings-panel="${this.section}"] h3`).focus()
        this.feedback('Each section saves separately.')
      }
    }
    this.onKey = event => {
      if (event.key === 'Escape' && !this.mayLeave()) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
    }
    this.el.addEventListener('input', this.onInput)
    document.addEventListener('click', this.onClick, true)
    window.addEventListener('keydown', this.onKey, true)
    this.showSection()
  },
  updated() {
    const wasConfirming = this.confirmingSwitch
    this.confirmingSwitch = !!this.el.querySelector('#agent-switch-confirmation')
    if (this.version !== this.el.dataset.saveVersion) {
      this.version = this.el.dataset.saveVersion
      this.dirty = false
      const secret = this.el.querySelector('#secret-value')
      if (secret) secret.value = ''
    }
    if (this.el.dataset.saveState === 'error' && this.section === 'secrets') {
      this.el.querySelector('#secret-value').value = ''
    }
    this.showSection()
    if (wasConfirming && !this.confirmingSwitch && this.el.dataset.saveState !== 'saving') {
      this.el.querySelector('[data-switch-agent]')?.focus()
    }
    if (this.dirty && !this.el.dataset.saveState) this.feedback('Unsaved changes')
  },
  mayLeave() {
    if (this.el.querySelector('#agent-switch-confirmation')) {
      this.feedback('Confirm or cancel the agent switch before leaving.')
      this.el.querySelector('#confirm-agent-switch')?.focus()
      return false
    }
    if (this.el.dataset.saveState === 'saving') {
      this.feedback('Saving… Wait for this save to finish before leaving.')
      return false
    }
    if (this.dirty) {
      this.feedback('Save this section or discard your changes before leaving.')
      this.el.querySelector(`[data-settings-panel="${this.section}"] form button.primary:not([hidden])`)?.focus()
      return false
    }
    return true
  },
  discard() {
    const panel = this.el.querySelector(`[data-settings-panel="${this.section}"]`)
    panel.querySelectorAll('form').forEach(form => form.reset())
    panel.querySelectorAll('input[type="password"]').forEach(input => { input.value = '' })
    if (this.section === 'agent') {
      if (this.el.dataset.component) this.pushEventTo(this.el.dataset.component, 'discard-agent', {})
      this.models(this.el.querySelector('#settings-runtime').value, this.el.dataset.savedModel)
    }
    this.dirty = false
    this.showSection()
    this.feedback('Changes discarded.')
    panel.querySelector('h3').focus()
  },
  feedback(text) {
    this.el.querySelector('[data-settings-feedback]').textContent = text
  },
  showSection() {
    const runtime = this.el.querySelector('#settings-runtime')
    const switching = runtime?.value !== this.el.dataset.savedRuntime
    const save = this.el.querySelector('[data-save-agent]')
    const rebuild = this.el.querySelector('[data-switch-agent]')
    if (save) save.hidden = switching
    if (rebuild) rebuild.hidden = !switching

    const discard = this.el.querySelector('[data-settings-discard]')
    discard.hidden = !this.dirty
    discard.disabled = this.el.dataset.saveState === 'saving' || !!this.el.querySelector('#agent-switch-confirmation')

    this.el.querySelectorAll('[data-settings-panel]').forEach(panel => {
      panel.hidden = panel.dataset.settingsPanel !== this.section
    })
    this.el.querySelectorAll('[data-settings-section]').forEach(button => {
      button.dataset.dirty = String(this.dirty && button.dataset.settingsSection === this.section)
      button.setAttribute('aria-current', String(button.dataset.settingsSection === this.section))
    })
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
    document.removeEventListener('click', this.onClick, true)
    window.removeEventListener('keydown', this.onKey, true)
  },
}
