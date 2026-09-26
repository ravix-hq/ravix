// Horizontal track navigation needs to work with ordinary mouse wheels as
// well as touch/trackpads. Keep the selected link visible on navigation, but
// let people scroll away from it while unrelated LiveView updates arrive.
export const TrackTabs = {
  mounted() {
    this.strip = this.el.querySelector('.track-tabs')
    this.left = this.el.querySelector('[data-scroll-left]')
    this.right = this.el.querySelector('[data-scroll-right]')
    this.measure = () => {
      this.left.disabled = this.strip.scrollLeft <= 0
      this.right.disabled = this.strip.scrollLeft + this.strip.clientWidth >= this.strip.scrollWidth - 1
    }
    this.backward = () => this.strip.scrollBy({left: -this.strip.clientWidth * 0.8})
    this.forward = () => this.strip.scrollBy({left: this.strip.clientWidth * 0.8})
    this.wheel = event => {
      // Leave horizontal gestures and browser zoom to the browser.
      if (event.ctrlKey || event.shiftKey || event.deltaX || !event.deltaY) return
      const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? this.strip.clientWidth : 1
      const before = this.strip.scrollLeft
      this.strip.scrollLeft += event.deltaY * unit
      if (this.strip.scrollLeft !== before) event.preventDefault()
    }
    this.left.addEventListener('click', this.backward)
    this.right.addEventListener('click', this.forward)
    this.strip.addEventListener('wheel', this.wheel, {passive: false})
    this.strip.addEventListener('scroll', this.measure)
    this.observer = new ResizeObserver(this.measure)
    this.observer.observe(this.strip)
    this.updated()
  },
  updated() {
    const selected = this.strip.querySelector('[aria-current="page"]')
    const href = selected?.getAttribute('href')
    if (href !== this.selectedHref) {
      selected?.scrollIntoView({block: 'nearest', inline: 'nearest'})
      this.selectedHref = href
    }
    this.measure()
  },
  destroyed() {
    this.observer.disconnect()
    this.left.removeEventListener('click', this.backward)
    this.right.removeEventListener('click', this.forward)
    this.strip.removeEventListener('wheel', this.wheel)
    this.strip.removeEventListener('scroll', this.measure)
  },
}
