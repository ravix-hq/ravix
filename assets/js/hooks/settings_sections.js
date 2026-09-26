// Settings navigation and loss-of-input warnings must run before LiveView's
// click/escape handlers. Keep only a dirty boolean; never copy secret values.
export const SettingsSections = {
  mounted() {
    this.section = 'general'
    this.dirty = false
    this.version = this.el.dataset.saveVersion
    this.onInput = event => {
      if (!event.target.closest('form')) return
      this.dirty = true
      this.feedback('Unsaved changes')
      if (event.target.id === 'settings-runtime') this.models(event.target.value)
    }
    this.onClick = event => {
      const secret = event.target.closest('[data-secret-action]')
      if (secret) {
        this.el.querySelector('#secret-store').value = secret.dataset.secretStore
        this.el.querySelector('#secret-key').value = secret.dataset.secretKey
        this.el.querySelector('#secret-value').value = ''
        this.el.querySelector('#secret-value').focus()
        this.dirty = true
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
        this.el.querySelector(`[data-settings-panel="${this.section}"] form`)?.reset()
        if (this.section === 'agent') {
          this.models(this.el.querySelector('#settings-runtime').value, this.el.dataset.savedModel)
        }
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
    this.onUnload = event => {
      if (this.dirty || this.el.dataset.saveState === 'saving') {
        event.preventDefault()
        event.returnValue = ''
      }
    }
    this.el.addEventListener('input', this.onInput)
    document.addEventListener('click', this.onClick, true)
    window.addEventListener('keydown', this.onKey, true)
    window.addEventListener('beforeunload', this.onUnload)
    this.showSection()
  },
  updated() {
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
    if (this.dirty && !this.el.dataset.saveState) this.feedback('Unsaved changes')
  },
  mayLeave() {
    if (this.el.dataset.saveState === 'saving') {
      this.feedback('Saving… Wait for this save to finish before leaving.')
      return false
    }
    return !this.dirty || window.confirm('Discard unsaved changes in this section?')
  },
  feedback(text) {
    this.el.querySelector('[data-settings-feedback]').textContent = text
  },
  showSection() {
    this.el.querySelectorAll('[data-settings-panel]').forEach(panel => {
      panel.hidden = panel.dataset.settingsPanel !== this.section
    })
    this.el.querySelectorAll('[data-settings-section]').forEach(button => {
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
    window.removeEventListener('beforeunload', this.onUnload)
  },
}
