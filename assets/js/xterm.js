// xterm.js, on its own: the interactive terminal's renderer.
//
// A bundle of its own rather than a part of app.js, because it is most of
// the size of everything else put together and most pages never open a
// terminal. `hooks/shell.js` loads it the first time one is shown, and
// finds it on `window.RavixXterm`. Built by the `xterm` esbuild profile
// (config/config.exs), minified by `mix assets.deploy` like app.js.
//
// The library is vendored (`assets/vendor/xterm/`), as Phoenix vendors
// browser code, so building assets needs no `node_modules`: not in the
// Docker image, and not in CI's release job. The version is pinned in
// package.json, and assets/test/vendor.test.js fails if the vendored files
// are not byte-for-byte that version's. To upgrade: `bun add --dev --exact`
// the new versions, then copy `lib/xterm.mjs`, `css/xterm.css` and
// `lib/addon-fit.mjs` (and the licenses) over the ones in vendor/xterm.
import {Terminal} from "../vendor/xterm/xterm.mjs"
import {FitAddon} from "../vendor/xterm/addon-fit.mjs"
import "../vendor/xterm/xterm.css"

window.RavixXterm = {Terminal, FitAddon}
