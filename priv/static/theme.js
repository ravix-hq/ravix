// Apply the saved palette before the stylesheet paints.
try {
  const saved = localStorage.getItem("ravix.theme")
  if (saved) document.documentElement.setAttribute("data-theme", saved)
} catch {}

// Sidebar visibility is the same kind of preference. The keys match
// PanelToggle in assets/js/hooks/panel_toggle.js; layouts tests keep them
// the same string.
try {
  if (localStorage.getItem("ravix.panel.yard") === "closed") {
    document.documentElement.dataset.yard = "closed"
  }
  if (localStorage.getItem("ravix.panel.inspector") === "closed") {
    document.documentElement.dataset.inspector = "closed"
  }
} catch {}
