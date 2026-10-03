defmodule RavixWeb.ImageSizesTest do
  @moduledoc """
  Every `<img>` the app draws carries its own `width` and `height` (RAV-138).

  An avatar is a GitHub image hundreds of pixels across, and the rule that
  shrinks it lives in `app.css`. A tab whose stylesheet predates that rule
  --- one left open across a deploy --- drew the Share button's viewer
  avatar at full size over the track header. The attributes are the size
  it falls back to with no rule at all.
  """
  use ExUnit.Case, async: true

  @sources Path.wildcard(Path.expand("../../lib/ravix_web/**/*.{ex,heex}", __DIR__))

  defp unsized(source) do
    ~r/<img\b[^>]*>/s
    |> Regex.scan(source)
    |> List.flatten()
    |> Enum.reject(&(&1 =~ ~r/\swidth=/ and &1 =~ ~r/\sheight=/))
  end

  test "no template draws an image without intrinsic dimensions" do
    found =
      for path <- @sources,
          tag <- unsized(File.read!(path)),
          do: {Path.relative_to_cwd(path), tag}

    assert found == []
  end

  test "the scan finds an image with either dimension missing, and passes one with both" do
    assert [_] = unsized(~s(<img :if={@url} src={@url} alt="" loading="lazy" />))
    assert [_] = unsized(~s(<img src={@url}\n  alt=""\n  width="20" />))
    assert [] = unsized(~s(<img\n  src={@url}\n  alt=""\n  width="20"\n  height="20"\n/>))
  end
end
