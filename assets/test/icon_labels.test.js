import {expect, test} from "bun:test"
import {mkdtempSync, mkdirSync, rmSync, writeFileSync} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {checkIconLabels, checkSource, iconOnly, sigils} from "../../scripts/icon_labels.mjs"

const check = source => checkSource({path: "t.heex", source})

test("the real templates pass: every icon-only control has a name and a tooltip", () => {
  expect(checkIconLabels()).toEqual([])
})

test("an icon-only button with neither a name nor a tooltip is rejected", () => {
  expect(check(`<button phx-click="x">\n  <.icon name="x" />\n</button>`)).toEqual([
    "t.heex:1: icon-only <button> needs an aria-label and a data-tip tooltip (or use <.icon_button>)",
  ])
})

test("a name without a tooltip, or a tooltip without a name, is rejected", () => {
  expect(check(`<button aria-label="Close"><.icon name="x" /></button>`).join()).toContain("needs a data-tip tooltip")
  expect(check(`<button data-tip="Close"><.icon name="x" /></button>`).join()).toContain("needs an aria-label")
  // A native title is neither: slow, mouse-only, and not the app's tooltip.
  expect(check(`<button title="Close"><.icon name="x" /></button>`).join()).toContain("needs an aria-label and a data-tip")
})

test("links, core buttons, summaries and self-closing controls are checked too", () => {
  for (const source of [
    `<.link navigate="/p"><.icon name="settings" /></.link>`,
    `<a href="/p"><svg></svg></a>`,
    `<.button phx-click="go"><.icon name="plus" /></.button>`,
    `<summary><.disclosure_chevron /></summary>`,
    `<button class="x" />`,
  ]) expect(check(source)).toHaveLength(1)
})

test("glyphs, hidden text and comments do not make a label", () => {
  for (const content of [
    "×",
    "⋯",
    "&times;",
    `<span aria-hidden="true">Close</span>`,
    `<span class="sr-only">Close</span>`,
    `<%!-- Close --%><.icon name="x" />`,
    `<.status_dot status="ok" />`,
  ]) expect(iconOnly(content)).toBe(true)
})

test("a control with words, an expression or a component is not icon-only", () => {
  for (const content of [
    `<.icon name="plus" />New track`,
    `{@label}`,
    `<.icon name="plus" /><span>Share</span>`,
    `<.option_label label={@label} />`,
  ]) expect(iconOnly(content)).toBe(false)
  expect(check(`<button><.icon name="plus" />New track</button>`)).toEqual([])
})

test("a named, tipped control is accepted however its attributes are written", () => {
  for (const source of [
    `<button aria-label="Close" data-tip="Close"><.icon name="x" /></button>`,
    `<button aria-labelledby="t" data-tip={@tip}><.icon name="x" /></button>`,
    `<button data-tip="Search"><.icon name="search" /><span class="sr-only">Search</span></button>`,
    `<.link patch={"/p/#{@id}"} aria-label={"Plans in #{@name}"} data-tip="Plans"><.icon name="document" /></.link>`,
    `<button phx-click={JS.push("a") |> JS.push("b")} aria-label="A > B" data-tip="A"><.icon name="x" /></button>`,
    `<.icon_button icon="x" label="Close" />`,
  ]) expect(check(source)).toEqual([])
})

test("nested controls are each judged on their own content", () => {
  const source = `<button aria-label="Outer" data-tip="Outer"><.icon name="x" />
    <button><.icon name="x" /></button></button>`
  expect(check(source)).toEqual([
    "t.heex:2: icon-only <button> needs an aria-label and a data-tip tooltip (or use <.icon_button>)",
  ])
})

test("~H sigils in Elixir files are read, with the file's line numbers", () => {
  const root = mkdtempSync(join(tmpdir(), "ravix-icons-"))
  try {
    mkdirSync(join(root, "lib/web"), {recursive: true})
    const ex = `defmodule A do\n  def a(assigns) do\n    ~H"""\n    <p>ok</p>\n    <button><.icon name="x" /></button>\n    """\n  end\nend\n`
    writeFileSync(join(root, "lib/web/a.ex"), ex)
    writeFileSync(join(root, "lib/web/b.html.heex"), `<button aria-label="B" data-tip="B"><.icon name="x" /></button>\n`)
    writeFileSync(join(root, "lib/web/c.txt"), `<button><.icon name="x" /></button>`)
    expect(sigils("a.ex", ex)).toHaveLength(1)
    expect(checkIconLabels(root)).toEqual([
      "lib/web/a.ex:5: icon-only <button> needs an aria-label and a data-tip tooltip (or use <.icon_button>)",
    ])
  } finally {
    rmSync(root, {recursive: true, force: true})
  }
})

test("the command line fails on a finding and passes on the real repository", () => {
  const script = new URL("../../scripts/icon_labels.mjs", import.meta.url).pathname
  const pass = Bun.spawnSync([process.execPath, script], {stdout: "pipe", stderr: "pipe"})
  expect(pass.exitCode).toBe(0)
  const root = mkdtempSync(join(tmpdir(), "ravix-icons-"))
  try {
    mkdirSync(join(root, "lib"))
    writeFileSync(join(root, "lib/a.heex"), `<button><.icon name="x" /></button>`)
    const fail = Bun.spawnSync([process.execPath, script], {cwd: root, stdout: "pipe", stderr: "pipe"})
    expect(fail.exitCode).toBe(1)
    expect(fail.stderr.toString()).toContain("lib/a.heex:1: icon-only <button>")
  } finally {
    rmSync(root, {recursive: true, force: true})
  }
})
