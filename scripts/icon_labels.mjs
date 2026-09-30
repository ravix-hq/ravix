// The icon-only control guard (RAV-98). A button or link whose content is
// only an icon has no name unless it carries one, and nothing to show a
// pointer user what it does unless it has a tooltip. This reads every HEEx
// template (`.heex` files and `~H` sigils) and reports each icon-only
// `<button>`, `<a>`, `<.link>`, `<.button>` or `<summary>` that has no
// accessible name (`aria-label`, `aria-labelledby` or visually hidden text)
// or no `data-tip`, the tooltip `assets/js/tooltip.js` draws.
// `<.icon_button>` is the component that carries both, and is always accepted.
//
// "Icon-only" means: once icons, `aria-hidden` and visually hidden
// (`sr-only`) elements, tags and comments are removed, no word and no
// `{expression}` is left; a glyph such as × or ⋯ is not a word. A control
// whose label is an expression, or a function component other than an icon
// (`ICONS`), is taken at its word, since the scanner cannot know what it
// prints.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const CONTROLS = ['button', 'a', '.link', '.button', 'summary'];
// The function components that draw no words.
const ICONS = ['.icon', '.disclosure_chevron', '.status_dot'];

// Every template source under `dir`: `.heex` files whole, `.ex` files' `~H` sigils.
export function templates(dir) {
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...templates(path));
    else if (name.endsWith('.heex')) out.push({ path, source: readFileSync(path, 'utf8') });
    else if (name.endsWith('.ex')) out.push(...sigils(path, readFileSync(path, 'utf8')));
  }
  return out;
}

// The bodies of `~H"""` heredocs, with each one's offset in the file for line numbers.
export function sigils(path, text) {
  const out = [];
  const open = /~H"""\n/g;
  let match;
  while ((match = open.exec(text))) {
    const start = match.index + match[0].length;
    const end = text.indexOf('"""', start);
    if (end < 0) break;
    out.push({ path, offset: start, source: text.slice(start, end), file: text });
    open.lastIndex = end + 3;
  }
  return out;
}

// Where the opening tag that starts at `start` ends (the index after `>`),
// skipping quoted values and `{...}` expressions, and whether it self-closes.
function openingTag(source, start) {
  let depth = 0;
  let quote = false;
  for (let i = start + 1; i < source.length; i++) {
    const c = source[i];
    if (quote) { if (c === '"' && source[i - 1] !== '\\') quote = false; continue; }
    if (c === '"') quote = true;
    else if (c === '{') depth++;
    else if (c === '}') depth--;
    else if (c === '>' && depth === 0) return { end: i + 1, selfClosing: source[i - 1] === '/' };
  }
  return null;
}

// The index of the `</name>` that closes the element whose content starts at `from`.
function closingTag(source, name, from) {
  const tags = new RegExp(`<(/?)${name.replace('.', '\\.')}(?=[\\s>/])`, 'g');
  tags.lastIndex = from;
  let depth = 1;
  let match;
  while ((match = tags.exec(source))) {
    if (match[1]) { if (--depth === 0) return match.index; continue; }
    const tag = openingTag(source, match.index);
    if (tag && !tag.selfClosing) depth++;
  }
  return -1;
}

const attribute = (tag, name) => new RegExp(`\\s${name}(?=[\\s=/>])`).test(tag);

const HIDDEN = /<([.\w-]+)\b[^>]*?\saria-hidden(?:=(?:"true"|\{true\}))?[\s/>]/;
const SR_ONLY = /<([.\w-]+)\b[^>]*?\sclass="(?:[^"]*\s)?sr-only(?:\s[^"]*)?"[\s/>]/;

// `text` without the elements whose opening tag `pattern` matches, contents and all.
function without(text, pattern) {
  for (;;) {
    const found = pattern.exec(text);
    if (!found) return text;
    const tag = openingTag(text, found.index);
    if (!tag) return text;
    let end = tag.end;
    if (!tag.selfClosing) {
      const close = closingTag(text, found[1], tag.end);
      if (close < 0) return text;
      end = text.indexOf('>', close) + 1;
    }
    text = text.slice(0, found.index) + text.slice(end);
  }
}

// The text left once comments, `aria-hidden` elements and every tag are
// gone. `visual` also removes visually hidden (`sr-only`) text, leaving
// what a sighted pointer user reads.
export function visibleText(content, { visual = false } = {}) {
  let text = content.replace(/<%!--[\s\S]*?--%>/g, '').replace(/<!--[\s\S]*?-->/g, '');
  text = without(text, HIDDEN);
  if (visual) text = without(text, SR_ONLY);
  // Tags go whole, so a `>` in one of their expressions cannot end one.
  let out = '';
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '<' && /[.\w/:!]/.test(text[i + 1] || '')) {
      const tag = openingTag(text, i);
      if (!tag) { out += text[i]; continue; }
      // A component other than an icon is taken to draw words.
      const component = /^<(\.[\w.]+)/.exec(text.slice(i, tag.end));
      if (component && !ICONS.includes(component[1])) out += '{component}';
      i = tag.end - 1;
      continue;
    }
    out += text[i];
  }
  return out.trim();
}

// Words: a letter, a digit or an `{expression}`. A glyph such as × is not one.
const words = text => /[\p{L}\p{N}{]/u.test(text.replace(/&[a-z]+;|&#\w+;/g, ''));

// No words a sighted user can read: nothing, or only glyphs such as ×, ⋯ or +.
export function iconOnly(content) {
  return !words(visibleText(content, { visual: true }));
}

// Every icon-only control in one template source that has no name or no tooltip.
export function checkSource({ path, offset = 0, source, file }, root = '.') {
  const problems = [];
  const opens = new RegExp(`<(${CONTROLS.map(n => n.replace('.', '\\.')).join('|')})(?=[\\s>/])`, 'g');
  let match;
  while ((match = opens.exec(source))) {
    const name = match[1];
    const tag = openingTag(source, match.index);
    if (!tag) continue;
    const attrs = source.slice(match.index, tag.end);
    let content = '';
    if (!tag.selfClosing) {
      const close = closingTag(source, name, tag.end);
      if (close < 0) continue;
      content = source.slice(tag.end, close);
    }
    if (!iconOnly(content)) continue;
    const missing = [];
    const named = attribute(attrs, 'aria-label') || attribute(attrs, 'aria-labelledby') || words(visibleText(content));
    if (!named) missing.push('an aria-label');
    if (!attribute(attrs, 'data-tip')) missing.push('a data-tip tooltip');
    if (missing.length === 0) continue;
    const line = ((file || source).slice(0, offset + match.index).match(/\n/g) || []).length + 1;
    problems.push(`${relative(root, path)}:${line}: icon-only <${name}> needs ${missing.join(' and ')} (or use <.icon_button>)`);
  }
  return problems;
}

export function checkIconLabels(root = '.') {
  return templates(join(root, 'lib')).flatMap(source => checkSource(source, root));
}

if (import.meta.main) {
  const problems = checkIconLabels();
  if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
  console.log('Icon-only controls: every one has an accessible name and a tooltip.');
}
