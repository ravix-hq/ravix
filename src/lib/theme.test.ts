import { describe, expect, test } from "bun:test";
import { DEFAULT_THEME, isThemeId, THEME_KEY, THEMES } from "./theme";

/**
 * The theme list is a list of ids that only mean anything if `styles.css` has
 * a block for each of them, and a missing token there does not fail loudly —
 * it falls back to the default palette's value, so a Dracula shell with one
 * near-black panel in it looks like a design choice rather than a bug. These
 * assertions are the thing that notices.
 */

const css = await Bun.file(new URL("../styles.css", import.meta.url)).text();
const html = await Bun.file(new URL("../../index.html", import.meta.url)).text();

/** Every colour the shell draws with. The default block is the definition. */
const TOKENS = [
  "bg", "panel", "sidebar", "surface", "surface-hover", "surface-active", "input", "code-bg",
  "line", "line-strong", "ink", "dim", "dimmer", "accent", "accent-ink", "accent-soft",
  "accent-line", "notice", "ok", "ok-soft", "warn", "warn-soft", "bad", "bad-soft",
  "danger-bg", "danger-line", "shadow", "scrim",
];

function block(selector: string): string {
  const found = new RegExp(`${selector}\\s*\\{([^}]*)\\}`).exec(css);
  expect(found, `no CSS block for ${selector}`).not.toBeNull();
  return found?.[1] ?? "";
}

describe("themes", () => {
  test("the ids are unique, and only they validate", () => {
    expect(new Set(THEMES.map((t) => t.id)).size).toBe(THEMES.length);
    for (const t of THEMES) expect(isThemeId(t.id)).toBe(true);
    expect(isThemeId("gruvbox")).toBe(false);
    expect(isThemeId("")).toBe(false);
    expect(isThemeId(null)).toBe(false);
    expect(isThemeId(undefined)).toBe(false);
  });

  test("the default is a real theme and shares its block with :root", () => {
    expect(isThemeId(DEFAULT_THEME)).toBe(true);
    expect(THEMES.findIndex((t) => t.id === DEFAULT_THEME)).toBe(0);
    // Sharing the selector rather than repeating it is what keeps an unthemed
    // page and an explicitly defaulted one from drifting apart.
    expect(css).toContain(`:root, [data-theme="${DEFAULT_THEME}"]`);
  });

  test("every theme has a complete palette and declares its colour scheme", () => {
    for (const theme of THEMES) {
      const selector = theme.id === DEFAULT_THEME ? `:root, \\[data-theme="${theme.id}"\\]` : `\\[data-theme="${theme.id}"\\]`;
      const body = block(selector);
      for (const token of TOKENS) expect(body, `${theme.id} is missing --${token}`).toContain(`--${token}:`);
      expect(body, `${theme.id} must declare color-scheme: ${theme.mode}`).toContain(`color-scheme: ${theme.mode}`);
    }
  });

  test("the palettes are not anchored to :root, so a swatch can carry one", () => {
    // The picker draws each preview by putting `data-theme` on a <span>. That
    // only resolves if the selectors match any element, not just <html>.
    expect(css).not.toContain(':root[data-theme="');
  });

  test("index.html applies the same storage key this module owns", () => {
    expect(THEME_KEY).toBe("switchyard.theme");
    expect(html).toContain(`localStorage.getItem("${THEME_KEY}")`);
    expect(html).toContain('setAttribute("data-theme"');
  });
});
