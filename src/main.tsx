import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { applyTheme, storedTheme } from "./lib/theme";
import "./styles.css";

// `index.html` has already painted in whatever was saved; this re-applies it
// through the validating path, so a hand-edited or stale key resolves to a
// real theme rather than leaving `<html>` on an attribute that matches nothing.
applyTheme(storedTheme());

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
