defmodule RavixWeb.AssetsTest do
  @moduledoc """
  The bundle builds, and what it emits is the product's stylesheet.

  esbuild is the only build step: `app.js` imports `app.css`, so one run
  emits both beside each other under `priv/static/assets/js`, which is where
  the root layout points. The theme assertions are `src/lib/theme.test.ts`
  moved over: a theme id only means anything if the stylesheet has a block
  for it, and a missing token there does not fail loudly.
  """
  use ExUnit.Case, async: false

  # `async: false` because this writes the real bundle under priv/static, and
  # two tests building it at once would race on the same files.

  @out Path.expand("../../priv/static/assets/js", __DIR__)
  @source Path.expand("../../assets/css/app.css", __DIR__)
  @themes ~w(ravix slate one-dark dracula nord tokyo-night catppuccin-mocha night-owl monokai
             gruvbox-dark solarized-dark daylight github-light one-light solarized-light
             catppuccin-latte mario neon-noir vaporwave matrix hot-dog-stand bubblegum)
  @tokens ~w(bg panel sidebar surface surface-hover surface-active input code-bg line line-strong
             ink dim dimmer accent accent-ink accent-soft accent-line notice ok ok-soft warn
             warn-soft bad bad-soft danger-bg danger-line shadow scrim)

  setup_all do
    # A build that fails exits non-zero, which raises here.
    0 = Esbuild.run(:ravix, [])

    %{
      css: File.read!(Path.join(@out, "app.css")),
      js: File.read!(Path.join(@out, "app.js")),
      source: File.read!(@source)
    }
  end

  test "the bundle emits the stylesheet beside the script", %{css: css} do
    assert css =~ ".theme-picker"
    assert css =~ ".composer-box"
    assert css =~ ".panel-resize-handle"
    assert css =~ ".jump-latest"
    assert css =~ "[hidden]"
    # esbuild drops the quotes; the palettes survive the trip.
    assert css =~ "[data-theme=nord]"
  end

  # Against the source rather than the bundle: esbuild rewrites the selector
  # lists, and the SPA's test was written against the file as authored.
  test "every theme has a complete palette and declares its colour scheme", %{source: css} do
    for theme <- @themes do
      selector =
        if theme == "ravix",
          do: ~s(:root, [data-theme="ravix"]),
          else: ~s([data-theme="#{theme}"])

      [_, body] =
        Regex.run(~r/#{Regex.escape(selector)}\s*\{([^}]*)\}/, css) ||
          flunk("no CSS block for #{theme}")

      for token <- @tokens do
        assert body =~ "--#{token}:", "#{theme} is missing --#{token}"
      end

      assert body =~ "color-scheme:"
    end

    # The picker draws each preview by putting `data-theme` on a <span>. That
    # only resolves if the selectors match any element, not just <html>.
    refute css =~ ~s(:root[data-theme=")
  end

  test "the script registers the five hooks and nothing else", %{js: js} do
    for hook <- ~w(Theme PanelResize TranscriptTail Composer Terminal) do
      assert js =~ hook
    end

    refute js =~ "topbar"
    refute js =~ "colocated"
  end
end
