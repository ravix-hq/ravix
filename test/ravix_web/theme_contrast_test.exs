defmodule RavixWeb.ThemeContrastTest do
  @moduledoc """
  The stylesheet's two colour contracts, read off `app.css` as authored.

  The first is legibility: every palette must put its text tokens on its
  grounds at WCAG AA (4.5:1) for body copy. The browser suite runs Axe
  against two themes; this covers the other twenty, and the pairs it checks
  are the ones the shell actually draws as sentences — `--dimmer` is the
  colour of hints, placeholders and the yard's captions, not a decoration.

  The second is the file's own rule from its head comment: every colour is a
  token, and nothing below the palettes hard-codes a hex value. A hex in the
  body is a colour one theme cannot change.
  """
  use ExUnit.Case, async: true

  @source Path.expand("../../assets/css/app.css", __DIR__)
  @aa 4.5
  @pairs [
    {"dimmer", "bg"},
    {"dimmer", "panel"},
    {"dim", "bg"},
    {"accent", "bg"},
    {"bad", "panel"},
    {"ink", "bg"}
  ]

  setup_all do
    %{css: File.read!(@source)}
  end

  describe "every palette" do
    test "puts its text tokens on its grounds at WCAG AA", %{css: css} do
      palettes = palettes(css)
      assert length(palettes) == 22, "expected the twenty-two palettes"

      failures =
        for {theme, tokens} <- palettes,
            {fg, bg} <- @pairs,
            ratio = contrast(Map.fetch!(tokens, fg), Map.fetch!(tokens, bg)),
            ratio < @aa,
            do: "#{theme}: --#{fg} on --#{bg} is #{Float.round(ratio, 2)}:1"

      assert failures == [], Enum.join(["below #{@aa}:1:" | failures], "\n  ")
    end
  end

  describe "below the palettes" do
    test "no colour is a hex literal", %{css: css} do
      {_palettes, body} = split_at_palettes(css)

      literals =
        body
        |> strip_comments()
        |> declaration_bodies()
        |> Enum.flat_map(fn declarations ->
          declarations
          |> String.replace(~r/url\([^)]*\)/, "")
          |> then(&Regex.scan(~r/#[0-9a-fA-F]{3,8}\b/, &1))
          |> List.flatten()
        end)

      assert literals == [], "hex literals outside the palettes: #{inspect(literals)}"
    end

    test "the split really is at the last palette", %{css: css} do
      {palettes, body} = split_at_palettes(css)
      assert palettes =~ ~s([data-theme="bubblegum"])
      refute body =~ ~s([data-theme=")
      assert body =~ "body {"
    end
  end

  # ── parsing ────────────────────────────────────────────────────────────

  # `[data-theme="x"] { ... }` blocks, plus the default that shares its
  # selector with `:root`, each as a map from token name to a colour value.
  defp palettes(css) do
    ~r/(?::root,\s*)?\[data-theme="([\w-]+)"\]\s*\{([^}]*)\}/
    |> Regex.scan(css)
    |> Enum.map(fn [_, theme, block] -> {theme, tokens(block)} end)
  end

  defp tokens(block) do
    ~r/--([\w-]+):\s*([^;]+);/
    |> Regex.scan(block)
    |> Map.new(fn [_, name, value] -> {name, String.trim(value)} end)
  end

  # Everything after the closing brace of the last `[data-theme]` block.
  defp split_at_palettes(css) do
    [{start, _}] =
      Regex.run(~r/\[data-theme="[\w-]+"\]\s*\{[^}]*\}(?![\s\S]*\[data-theme=")/, css,
        return: :index
      )

    {open, _} = :binary.match(css, "{", scope: {start, byte_size(css) - start})
    {close, _} = :binary.match(css, "}", scope: {open, byte_size(css) - open})
    {binary_part(css, 0, close + 1), binary_part(css, close + 1, byte_size(css) - close - 1)}
  end

  defp strip_comments(css), do: Regex.replace(~r/\/\*.*?\*\//s, css, "")

  # The text inside braces, which is where a colour value could sit. The
  # selectors outside them are where `#new-track-form` lives.
  defp declaration_bodies(css) do
    ~r/\{([^{}]*)\}/
    |> Regex.scan(css)
    |> Enum.map(fn [_, inner] -> inner end)
  end

  # ── WCAG ───────────────────────────────────────────────────────────────

  defp contrast(fg, bg) do
    {lf, lb} = {luminance(rgb(fg)), luminance(rgb(bg))}
    (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
  end

  # Relative luminance of an sRGB colour, per WCAG 2.x.
  defp luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(&channel/1)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp channel(c) do
    c = c / 255
    if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
  end

  # `#rgb`, `#rrggbb`, `#rrggbbaa` or `rgba(r, g, b, a)`. Alpha is dropped: a
  # translucent colour is judged as if painted opaque, which is the harsher
  # reading for a scrim and the only one that needs no compositing.
  defp rgb("#" <> hex) when byte_size(hex) == 3 do
    hex |> String.graphemes() |> Enum.map(&String.to_integer(&1 <> &1, 16)) |> List.to_tuple()
  end

  defp rgb("#" <> hex) when byte_size(hex) in [6, 8] do
    hex
    |> binary_part(0, 6)
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(&String.to_integer(Enum.join(&1), 16))
    |> List.to_tuple()
  end

  defp rgb("rgba(" <> rest) do
    rest
    |> String.trim_trailing(")")
    |> String.split(",")
    |> Enum.take(3)
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
    |> List.to_tuple()
  end
end
