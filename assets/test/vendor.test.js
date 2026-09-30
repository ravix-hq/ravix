import {expect, test} from "bun:test"
import {readFileSync} from "node:fs"

// The terminal's renderer is vendored so building assets needs no
// node_modules (assets/js/xterm.js). package.json pins the version; this is
// what keeps the vendored copy honestly that version, and not a hand-edited
// or half-upgraded one.
const root = new URL("../../", import.meta.url).pathname
const pkg = JSON.parse(readFileSync(`${root}package.json`, "utf8"))
const read = path => readFileSync(`${root}${path}`)

test.each([
  ["@xterm/xterm", "lib/xterm.mjs", "xterm.mjs"],
  ["@xterm/xterm", "css/xterm.css", "xterm.css"],
  ["@xterm/xterm", "LICENSE", "LICENSE.xterm"],
  ["@xterm/addon-fit", "lib/addon-fit.mjs", "addon-fit.mjs"],
  ["@xterm/addon-fit", "LICENSE", "LICENSE.addon-fit"],
])("vendored %s %s is the pinned release's", (name, file, vendored) => {
  const pinned = pkg.devDependencies[name]
  expect(pinned).toMatch(/^\d+\.\d+\.\d+$/)
  expect(JSON.parse(read(`node_modules/${name}/package.json`)).version).toBe(pinned)
  expect(read(`assets/vendor/xterm/${vendored}`).equals(read(`node_modules/${name}/${file}`))).toBe(true)
})
