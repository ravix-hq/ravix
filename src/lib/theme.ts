/**
 * Which palette is on.
 *
 * The mechanism is one attribute. Every colour in `styles.css` is a custom
 * property declared under `[data-theme="…"]`, so setting that attribute on
 * `<html>` re-themes the whole app — including any component written after
 * this file, which is the point of the app never hard-coding a hex.
 *
 * Two consequences worth knowing before adding a theme:
 *
 *   - The attribute is not special to `<html>`. The selectors are plain
 *     attribute selectors rather than `:root[data-theme]`, so a `<span>` that
 *     carries `data-theme="nord"` resolves `var(--bg)` to Nord's background.
 *     That is how the picker draws a live swatch per theme without a swatch
 *     class per theme, and it means a swatch cannot drift from its palette.
 *   - `switchyard` is the default, and its block shares a selector list with
 *     `:root` rather than repeating it. So an unthemed page and an explicitly
 *     `switchyard`-themed one are the same declarations, not two copies that
 *     have to be kept in step.
 *
 * The list is the IDE canon plus this app's own two, because a person who has
 * spent a decade in one editor's colours reads a diff faster in them, and the
 * transcript here is mostly diffs — then a handful that are the opposite of
 * that argument, and are marked `fun` so the menu can keep them apart. A
 * palette nobody would pick to read a stack trace in is still one somebody
 * wants on the machine on a Friday, and mixing the two lists would cost the
 * canon its "these are the colours you already know" reading.
 */

/**
 * A named palette. `mode` is the `color-scheme` its CSS block must declare;
 * `fun` moves it out of the Dark/Light groups into its own.
 */
export interface ThemeDef {
  id: string;
  name: string;
  mode: "dark" | "light";
  fun?: boolean;
}

export const THEMES = [
  { id: "switchyard", name: "Switchyard", mode: "dark" },
  { id: "slate", name: "Slate", mode: "dark" },
  { id: "one-dark", name: "One Dark", mode: "dark" },
  { id: "dracula", name: "Dracula", mode: "dark" },
  { id: "nord", name: "Nord", mode: "dark" },
  { id: "tokyo-night", name: "Tokyo Night", mode: "dark" },
  { id: "catppuccin-mocha", name: "Catppuccin Mocha", mode: "dark" },
  { id: "night-owl", name: "Night Owl", mode: "dark" },
  { id: "monokai", name: "Monokai", mode: "dark" },
  { id: "gruvbox-dark", name: "Gruvbox Dark", mode: "dark" },
  { id: "solarized-dark", name: "Solarized Dark", mode: "dark" },
  { id: "daylight", name: "Daylight", mode: "light" },
  { id: "github-light", name: "GitHub Light", mode: "light" },
  { id: "one-light", name: "One Light", mode: "light" },
  { id: "solarized-light", name: "Solarized Light", mode: "light" },
  { id: "catppuccin-latte", name: "Catppuccin Latte", mode: "light" },
  { id: "mario", name: "Mario", mode: "dark", fun: true },
  { id: "neon-noir", name: "Neon Noir", mode: "dark", fun: true },
  { id: "vaporwave", name: "Vaporwave", mode: "dark", fun: true },
  { id: "matrix", name: "Matrix", mode: "dark", fun: true },
  { id: "hot-dog-stand", name: "Hot Dog Stand", mode: "dark", fun: true },
  { id: "bubblegum", name: "Bubblegum", mode: "light", fun: true },
] as const satisfies readonly ThemeDef[];

export type ThemeId = (typeof THEMES)[number]["id"];

export const DEFAULT_THEME: ThemeId = "switchyard";

/**
 * The storage key, which is also written into `index.html`.
 *
 * The inline script there applies the saved palette before the stylesheet
 * paints, which is the only way to avoid a frame of the wrong background on a
 * hard reload — a module import runs too late for that. Two places holding one
 * string is a thing that rots, so `theme.test.ts` asserts they still match.
 */
export const THEME_KEY = "switchyard.theme";

export function isThemeId(value: unknown): value is ThemeId {
  return THEMES.some((theme) => theme.id === value);
}

/** The saved palette, or the default if there is none or it is no longer real. */
export function storedTheme(): ThemeId {
  try {
    const saved = localStorage.getItem(THEME_KEY);
    return isThemeId(saved) ? saved : DEFAULT_THEME;
  } catch {
    // A private window, or site data switched off. The default palette is a
    // complete answer, so this is not worth telling anybody about.
    return DEFAULT_THEME;
  }
}

/** Paint in a palette without committing to it — the menu's hover preview. */
export function previewTheme(id: ThemeId): void {
  document.documentElement.setAttribute("data-theme", id);
}

/** Paint in a palette and remember it. */
export function applyTheme(id: ThemeId): void {
  previewTheme(id);
  try {
    localStorage.setItem(THEME_KEY, id);
  } catch {
    // The theme still applies to this page; it just will not be remembered.
    // Failing the switch over that would be the worse outcome.
  }
}
