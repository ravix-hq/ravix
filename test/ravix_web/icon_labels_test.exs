defmodule RavixWeb.IconLabelsTest do
  @moduledoc """
  RAV-98's lint: an icon-only control in any template has a name and the
  app's tooltip. The first test is the gate over the real templates; the
  rest prove the scan rejects what it should and accepts what it should.
  """
  use ExUnit.Case, async: true

  alias RavixWeb.IconLabels

  @missing_both "icon-only <button> needs an aria-label and a data-tip tooltip (or use <.icon_button>)"

  defp check(source),
    do: IconLabels.check_source(%{path: "t.heex", source: source, offset: 0, file: source})

  test "every icon-only control in lib/ has a name and a tooltip" do
    assert IconLabels.check() == []
  end

  test "an icon-only button with neither a name nor a tooltip is rejected" do
    assert check(~s(<button phx-click="x">\n  <.icon name="x" />\n</button>)) == [
             "t.heex:1: " <> @missing_both
           ]
  end

  test "a name without a tooltip, a tooltip without a name, or a native title is rejected" do
    assert [problem] = check(~s(<button aria-label="Close"><.icon name="x" /></button>))
    assert problem =~ "needs a data-tip tooltip"
    refute problem =~ "aria-label"

    assert [problem] = check(~s(<button data-tip="Close"><.icon name="x" /></button>))
    assert problem =~ "needs an aria-label ("

    # A native title is neither: slow, mouse-only and without the shortcut.
    assert [problem] = check(~s(<button title="Close"><.icon name="x" /></button>))
    assert problem =~ "needs an aria-label and a data-tip"
  end

  test "links, core buttons, summaries and self-closing controls are checked too" do
    for source <- [
          ~s(<.link navigate="/p"><.icon name="settings" /></.link>),
          ~s(<a href="/p"><svg></svg></a>),
          ~s(<.button phx-click="go"><.icon name="plus" /></.button>),
          ~s(<summary><.disclosure_chevron /></summary>),
          ~s(<button class="x" />)
        ] do
      assert [_] = check(source), source
    end
  end

  test "glyphs, hidden text, comments and icons are not words" do
    for content <- [
          "×",
          "⋯",
          "&times;",
          ~s(<span aria-hidden="true">Close</span>),
          ~s(<span class="dim sr-only">Close</span>),
          ~s(<%!-- Close --%><.icon name="x" />),
          ~s(<.status_dot status="ok" />)
        ] do
      assert IconLabels.icon_only?(content), content
    end
  end

  test "words, an expression or another component make a control not icon-only" do
    for content <- [
          ~s(<.icon name="plus" />New track),
          "{@label}",
          ~s(<.icon name="plus" /><span>Share</span>),
          ~s(<.option_label label={@label} />)
        ] do
      refute IconLabels.icon_only?(content), content
    end

    assert check(~s(<button><.icon name="plus" />New track</button>)) == []
  end

  test "a named, tipped control is accepted however its attributes are written" do
    for source <- [
          ~s(<button aria-label="Close" data-tip="Close"><.icon name="x" /></button>),
          ~s(<button aria-labelledby="t" data-tip={@tip}><.icon name="x" /></button>),
          ~s(<button data-tip="Search"><.icon name="search" /><span class="sr-only">Search</span></button>),
          ~S'<.link patch={"/p/#{@id}"} aria-label={"Plans in #{@name}"} data-tip="Plans"><.icon name="document" /></.link>',
          ~S'<button phx-click={JS.push("a") |> JS.push("b")} aria-label="A > B" data-tip="A"><.icon name="x" /></button>',
          ~s(<.icon_button icon="x" label="Close" />)
        ] do
      assert check(source) == [], source
    end
  end

  test "nested controls are each judged on their own content" do
    source = """
    <button aria-label="Outer" data-tip="Outer"><.icon name="x" />
      <button><.icon name="x" /></button></button>
    """

    assert check(source) == ["t.heex:2: " <> @missing_both]
  end

  @tag :tmp_dir
  test "~H sigils are read with the file's own line numbers, and other files are not", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "lib/web"))

    File.write!(Path.join(root, "lib/web/a.ex"), """
    defmodule A do
      def a(assigns) do
        ~H\"""
        <p>ok</p>
        <button><.icon name="x" /></button>
        \"""
      end
    end
    """)

    File.write!(
      Path.join(root, "lib/web/b.html.heex"),
      ~s(<button aria-label="B" data-tip="B"><.icon name="x" /></button>\n<a href="/"><.icon name="x" /></a>\n)
    )

    File.write!(Path.join(root, "lib/web/c.txt"), ~s(<button><.icon name="x" /></button>))

    assert IconLabels.check(root) == [
             "lib/web/a.ex:5: " <> @missing_both,
             "lib/web/b.html.heex:2: icon-only <a> needs an aria-label and a data-tip tooltip (or use <.icon_button>)"
           ]
  end
end
