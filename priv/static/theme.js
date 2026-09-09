// Apply the saved palette before the stylesheet paints.
try {
  const saved = localStorage.getItem("ravix.theme")
  if (saved) document.documentElement.setAttribute("data-theme", saved)
} catch {}
