/**
 * Twenty-two palettes, behind one row in the foot of the yard.
 *
 * A menu rather than a light/dark toggle, because the list is the editor canon
 * and the whole value of it is that somebody who has read diffs in Gruvbox for
 * six years gets to read this app's diffs in Gruvbox too. Names matter for the
 * same reason, so they are spelled out rather than cycled through.
 *
 * The `fun` ones get a group of their own at the bottom rather than a place in
 * Dark. They are the same shape and cost the picker nothing, but sorting them
 * by `mode` would file Vaporwave next to Nord, and the canon's whole promise is
 * that everything in it is somebody's daily driver.
 *
 * Hovering a row paints the app in that theme immediately and leaving the menu
 * puts back the one that is actually on. That is worth the small amount of
 * bookkeeping below: a swatch tells you the background and the accent, and
 * nothing else, and the thing you are choosing is how a transcript reads.
 */
import { useEffect, useRef, useState } from "react";
import { THEMES, applyTheme, previewTheme, storedTheme, type ThemeId } from "../lib/theme";
import { Check, Chevron } from "../lib/icons";

const isFun = (t: (typeof THEMES)[number]) => "fun" in t && t.fun;
const DARK = THEMES.filter((t) => t.mode === "dark" && !isFun(t));
const LIGHT = THEMES.filter((t) => t.mode === "light" && !isFun(t));
const FUN = THEMES.filter(isFun);

export function ThemePicker() {
  const [theme, setTheme] = useState<ThemeId>(storedTheme);
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);

  // A shut menu means the palette on screen is the one in state — whichever of
  // the five ways out was taken: a choice, a click outside, Escape, the pointer
  // leaving, or the trigger being clicked again. One effect rather than a
  // restore at each exit, because the sixth exit is the one that forgets, and
  // what it leaves behind is an app that quietly changed colour on its own.
  useEffect(() => {
    if (!open) previewTheme(theme);
  }, [open, theme]);

  useEffect(() => {
    if (!open) return;
    const away = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);

  const current = THEMES.find((t) => t.id === theme) ?? THEMES[0];

  const choose = (id: ThemeId) => {
    applyTheme(id);
    setTheme(id);
    setOpen(false);
  };

  const option = (t: (typeof THEMES)[number]) => (
    <button
      key={t.id}
      type="button"
      role="menuitemradio"
      aria-checked={t.id === theme}
      className={`theme-option${t.id === theme ? " on" : ""}`}
      onMouseEnter={() => previewTheme(t.id)}
      onFocus={() => previewTheme(t.id)}
      onClick={() => choose(t.id)}
    >
      <span className="theme-swatch" data-theme={t.id} aria-hidden="true" />
      <span className="truncate">{t.name}</span>
      <span className="spacer" />
      {t.id === theme ? <Check size={13} className="check" /> : null}
    </button>
  );

  return (
    <div className="theme-picker" ref={box}>
      <button
        type="button"
        className="theme-trigger"
        aria-haspopup="menu"
        aria-expanded={open}
        title="Colour theme"
        onClick={() => setOpen((v) => !v)}
      >
        <span className="theme-swatch" data-theme={theme} aria-hidden="true" />
        <span className="col">
          <small>Theme</small>
          <span className="truncate">{current.name}</span>
        </span>
        {/* Up, because the menu opens upward out of the foot of the rail. */}
        <Chevron size={13} className="caret" style={{ transform: "rotate(-90deg)" }} />
      </button>

      {open ? (
        <div className="theme-menu" role="menu" aria-label="Colour theme" onMouseLeave={() => previewTheme(theme)}>
          <div className="theme-group">Dark</div>
          {DARK.map(option)}
          <div className="theme-group">Light</div>
          {LIGHT.map(option)}
          <div className="theme-group">Fun</div>
          {FUN.map(option)}
        </div>
      ) : null}
    </div>
  );
}
