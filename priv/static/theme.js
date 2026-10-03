// Resolve Auto before the stylesheet paints, including the first visit.
let appearance = "auto"
try {
  appearance = localStorage.getItem("ravix.theme") || "auto"
} catch {}
document.documentElement.setAttribute("data-theme",
  appearance === "auto" ? (matchMedia("(prefers-color-scheme: dark)").matches ? "slate" : "ravix") :
  appearance === "light" ? "ravix" : appearance === "dark" ? "slate" : appearance)

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
