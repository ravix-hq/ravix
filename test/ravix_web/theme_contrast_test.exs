defmodule RavixWeb.ThemeContrastTest do
  @moduledoc """
  The stylesheet's two colour contracts, read off `app.css` as authored.

  The first is legibility: every palette must put its text tokens on its
  grounds at WCAG AA (4.5:1) for body copy. The browser suite runs Axe
  against two themes; this covers the other twenty, and the pairs it checks
  are the ones the shell actually draws as sentences — `--dimmer` is the
  colour of hints, placeholders and the yard's captions, not a decoration.

  The Files tab's kinds of file are the same promise for graphics: every
  kind's colour, a token or a `color-mix` of two, is an icon that must clear
  WCAG's 3:1 for non-text contrast on the panel and on the selected row, in
  every palette. A colour is only "from the theme" if every theme can read it.

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

  describe "the Files tab's kinds of file" do
    test "are drawn at 3:1 or better on the panel and the selected row", %{css: css} do
      kinds = kinds(css)
      assert map_size(kinds) >= 10, "expected at least ten coloured kinds, got #{inspect(kinds)}"

      failures =
        for {theme, tokens} <- palettes(css),
            {kind, value} <- kinds,
            ground <- ["panel", "line"],
            colour = resolve(value, tokens),
            ratio = contrast(colour, rgb(Map.fetch!(tokens, ground))),
            ratio < 3.0,
            do: "#{theme}: #{kind} on --#{ground} is #{Float.round(ratio, 2)}:1"

      assert failures == [], Enum.join(["below 3:1:" | failures], "\n  ")
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

  # `.file-kind.kind-x { color: ... }`, as kind => the colour's source text.
  defp kinds(css) do
    ~r/\.file-kind\.kind-([\w-]+)\s*\{\s*color:\s*([^;]+);/
    |> Regex.scan(css)
    |> Map.new(fn [_, kind, value] -> {kind, String.trim(value)} end)
  end

  # A kind's colour in one palette, as `{r, g, b}`: a token, or an oklab mix
  # of two. Anything else fails to match, which is the point.
  defp resolve("var(--" <> rest, tokens),
    do: tokens |> Map.fetch!(String.trim_trailing(rest, ")")) |> rgb()

  defp resolve(value, tokens) do
    [_, a, share, b] =
      Regex.run(
        ~r/^color-mix\(in oklab, var\(--([\w-]+)\) (\d+)%, var\(--([\w-]+)\)\)$/,
        value
      )

    mix(rgb(tokens[a]), String.to_integer(share) / 100, rgb(tokens[b]))
  end

  # CSS Color 4's `color-mix` for two opaque colours: interpolate in OKLab,
  # then back to sRGB, clamped to the gamut.
  defp mix(a, share, b) do
    {l1, a1, b1} = oklab(a)
    {l2, a2, b2} = oklab(b)
    lerp = fn x, y -> x * share + y * (1 - share) end
    srgb({lerp.(l1, l2), lerp.(a1, a2), lerp.(b1, b2)})
  end

  defp oklab({r, g, b}) do
    [r, g, b] = Enum.map([r, g, b], &channel/1)
    l = :math.pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1 / 3)
    m = :math.pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1 / 3)
    s = :math.pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1 / 3)

    {0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s}
  end

  defp srgb({l, a, b}) do
    l_ = :math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
    m_ = :math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
    s_ = :math.pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)

    [
      4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
      -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
      -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
    ]
    |> Enum.map(fn c ->
      c = min(max(c, 0.0), 1.0)
      c = if c <= 0.0031308, do: 12.92 * c, else: 1.055 * :math.pow(c, 1 / 2.4) - 0.055
      c * 255
    end)
    |> List.to_tuple()
  end

  # ── WCAG ───────────────────────────────────────────────────────────────

  defp contrast({_, _, _} = fg, {_, _, _} = bg) do
    {lf, lb} = {luminance(fg), luminance(bg)}
    (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
  end

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
