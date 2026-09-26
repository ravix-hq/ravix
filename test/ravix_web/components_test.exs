defmodule RavixWeb.ComponentsTest do
  @moduledoc """
  The primitives render the markup the ported stylesheet was written for.

  Class names are the contract here: `app.css` is the SPA's stylesheet
  unchanged, so a component that emits `.dialog-head` gets the SPA's dialog
  head and one that emits anything else gets nothing.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.JS
  alias Ravix.People.InviteLink
  alias RavixWeb.CoreComponents
  alias RavixWeb.Layouts

  describe "icon/1" do
    test "draws a 24-grid stroke path by name" do
      html = render_component(&CoreComponents.icon/1, name: "machine", size: 20)
      assert html =~ ~s(viewBox="0 0 24 24")
      assert html =~ ~s(width="20")
      assert html =~ ~s(stroke="currentColor")
      assert html =~ ~s(<rect x="3" y="5" width="18" height="11" rx="2" />)
      assert html =~ ~s(aria-hidden="true")
    end

    test "github is filled, on its own grid" do
      html = render_component(&CoreComponents.icon/1, name: "github")
      assert html =~ ~s(viewBox="0 0 16 16")
      assert html =~ ~s(fill="currentColor")
      refute html =~ "stroke="
    end

    test "a chevron turns when open" do
      assert render_component(&CoreComponents.icon/1, name: "chevron", open: true) =~
               "rotate(90deg)"

      refute render_component(&CoreComponents.icon/1, name: "chevron") =~ "rotate"
    end

    test "every icon in the SPA's set has a name here" do
      spa = ~w(home plus search folder folder-plus file globe branch pull issue terminal play
               wrench check x dot picture pencil clock chevron spinner arrow-up external
               settings sparkle info machine add-person github code document copy more
               refresh person sign-out)

      assert Enum.sort(spa) == RavixWeb.Icons.names()
    end
  end

  describe "toast/1" do
    test "an error is bad and dismissable" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.toast id="t1" kind={:error}>Could not save.</CoreComponents.toast>
        """)

      assert html =~ ~s(class="toast bad")
      assert html =~ ~s(role="status")
      assert html =~ "Could not save."
      assert html =~ ~s(aria-label="Dismiss")
      assert html =~ "lv:clear-flash"
    end

    test "dismiss nil has no x" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.toast id="t2" dismiss={nil} hidden>Reconnecting</CoreComponents.toast>
        """)

      refute html =~ "Dismiss"
      assert html =~ "hidden"
      refute html =~ "bad"
    end
  end

  describe "flash/1 and the layout's flash group" do
    test "a flash is a toast, and no flash is nothing" do
      assert render_component(&CoreComponents.flash/1, kind: :info, flash: %{"info" => "Saved"}) =~
               "Saved"

      assert render_component(&CoreComponents.flash/1, kind: :info, flash: %{}) == ""
    end

    test "the group carries the reconnect toasts" do
      html = render_component(&Layouts.flash_group/1, flash: %{"error" => "Nope"})
      assert html =~ ~s(class="toasts")
      assert html =~ "Nope"
      assert html =~ ~s(id="client-error")
      assert html =~ ~s(id="server-error")
      assert html =~ "phx-disconnected"
    end
  end

  describe "dialog/1" do
    test "has the shell, closes on escape and the scrim, and traps focus" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.dialog id="pick" title="Pick one" on_close="close" wide>
          <div class="dialog-body">rows</div>
          <:footer><button>Go</button></:footer>
        </CoreComponents.dialog>
        """)

      assert html =~ ~s(class="scrim")
      assert html =~ ~s(class="dialog")
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="pick-title")
      assert html =~ ~s(<h2 id="pick-title">Pick one</h2>)
      assert html =~ ~s(class="dialog-head")
      assert html =~ ~s(class="dialog-foot")
      assert html =~ ~s(phx-key="escape")
      assert html =~ "phx-click-away"
      assert html =~ "phx-window-keydown"
      assert html =~ "focus_first"
      assert html =~ "min(860px, 100%)"
      assert html =~ ~s(aria-label="Close")
      assert html =~ "rows"
    end

    test "accepts a JS command to close" do
      html =
        render_component(&CoreComponents.dialog/1,
          id: "d",
          title: "T",
          on_close: JS.push("bye"),
          inner_block: [%{inner_block: fn _, _ -> "x" end}]
        )

      assert html =~ "bye"
      refute html =~ "dialog-foot"
    end
  end

  describe "invite_link/1" do
    test "the owner is offered both buttons, and they are the same two on either dialog" do
      html = render_component(&CoreComponents.invite_link/1, owner: true, invite: nil)
      assert html =~ ~s(phx-click="invite-link")
      assert html =~ ~s(phx-value-action="create")
      assert html =~ ~s(phx-value-action="revoke")
      assert html =~ "Create invite link"
      assert html =~ "Revoke invite link"
    end

    test "a member is offered neither" do
      html = render_component(&CoreComponents.invite_link/1, owner: false, invite: nil)
      refute html =~ "invite-link"
      refute html =~ "<button"
    end

    test "a freshly minted link is shown, once, as a link" do
      html =
        render_component(&CoreComponents.invite_link/1,
          owner: true,
          invite: %InviteLink{url: "https://ravix.test/j/tok", created_at: nil, expires_at: nil}
        )

      assert html =~ ~s(<a href="https://ravix.test/j/tok">https://ravix.test/j/tok</a>)
    end

    test "a link that is merely out has no url and is not shown" do
      # `Ravix.People.link/2` reports an existing link with `url: nil`, because
      # only its hash is kept. There is nothing to render and nothing to imply.
      html =
        render_component(&CoreComponents.invite_link/1,
          owner: true,
          invite: %InviteLink{
            url: nil,
            created_at: DateTime.utc_now(),
            expires_at: DateTime.utc_now()
          }
        )

      refute html =~ "<a href"
    end
  end

  describe "empty/1 and not_configured/1" do
    test "the empty state says what, why and what to do" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.empty icon="machine" title="No machine yet" because="Built on demand." soon>
          Nothing to type at. <:action label="Try again" click="retry" />
        </CoreComponents.empty>
        """)

      assert html =~ ~s(class="empty")
      assert html =~ ~s(class="mark")
      assert html =~ "<h3>No machine yet</h3>"
      assert html =~ "Nothing to type at."
      assert html =~ ~s(<p class="dimmer">Built on demand.</p>)
      assert html =~ ~s(class="soon">Coming soon)
      assert html =~ ~s(phx-click="retry")
      assert html =~ "Try again"
    end

    test "not configured names the variable" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.not_configured icon="terminal" title="Terminal" variable="SPRITES_TOKEN">
          Runs commands on the machine.
        </CoreComponents.not_configured>
        """)

      assert html =~ "<code>SPRITES_TOKEN</code>"
      assert html =~ "switched off here rather than unfinished"
      assert html =~ "Runs commands on the machine."
      refute html =~ "Coming soon"
    end
  end

  describe "wordmark/1" do
    test "draws RAVIX as blocks" do
      html = render_component(&CoreComponents.wordmark/1, [])
      assert html =~ ~s(class="wordmark")
      assert html =~ ~s(role="img")
      assert html =~ ~s(aria-label="RAVIX")
      # Five letters at a stride of 39 + 14, minus the trailing gap; seven rows of 8 minus one.
      assert html =~ ~s(viewBox="0 0 251 55")
      # R has 18 cells, A 18, V 13, I 15, X 13.
      assert length(Regex.scan(~r/<rect /, html)) == 18 + 18 + 13 + 15 + 13
    end

    test "unknown characters are skipped" do
      html = render_component(&CoreComponents.wordmark/1, text: "a-b")
      assert html =~ ~s(aria-label="a-b")
      # Only A survives: the dash is not a glyph and B is not in the set.
      assert length(Regex.scan(~r/<rect /, html)) == 18
    end
  end

  describe "the restyled generated set" do
    test "button variants are the stylesheet's modifiers, and no utility classes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button variant="primary" phx-click="go">Send</CoreComponents.button>
        """)

      assert html =~ ~s(class="primary")
      refute html =~ "btn"

      html =
        rendered_to_string(~H"""
        <CoreComponents.button navigate="/">Home</CoreComponents.button>
        """)

      assert html =~ ~s(<a href="/")
    end

    test "inputs sit in a field with a hint and errors" do
      html =
        render_component(&CoreComponents.input/1,
          name: "name",
          value: "",
          label: "Name",
          hint: "Shown in the rail.",
          errors: ["can't be blank"]
        )

      assert html =~ ~s(class="field")
      assert html =~ "<label"
      assert html =~ ~s(class="hint">Shown in the rail.)
      assert html =~ ~s(class="error fine">can&#39;t be blank)
      refute html =~ "fieldset"
    end

    test "a checkbox carries its hidden false" do
      html =
        render_component(&CoreComponents.input/1,
          type: "checkbox",
          name: "on",
          value: true,
          label: "On"
        )

      assert html =~ ~s(type="hidden" name="on" value="false")
      assert html =~ "checked"
    end

    test "a select renders its options" do
      html =
        render_component(&CoreComponents.input/1,
          type: "select",
          name: "k",
          value: "b",
          options: [{"A", "a"}, {"B", "b"}],
          prompt: "Pick"
        )

      assert html =~ ~s(<option value="">Pick</option>)
      assert html =~ ~s(<option selected value="b">B</option>)
    end

    test "header, table and list" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>
          Title<:subtitle>Sub</:subtitle>
          <:actions>A</:actions>
        </CoreComponents.header>
        <CoreComponents.table id="t" rows={[%{a: 1}]}>
          <:col :let={r} label="a">{r.a}</:col>
        </CoreComponents.table>
        <CoreComponents.list>
          <:item title="K">V</:item>
        </CoreComponents.list>
        """)

      assert html =~ ~r|<h2>\s*Title</h2>|
      assert html =~ "Sub"
      assert html =~ ~s(<tbody id="t">)
      assert html =~ ~s(class="keyline")
      refute html =~ "text-"
      refute html =~ "flex-"
    end
  end

  describe "the root layout" do
    test "paints the saved theme before the stylesheet and titles the tab Ravix" do
      html =
        Layouts.root(%{inner_content: "BODY", page_title: nil})
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ ~s|src="/theme.js"|
      assert File.read!("priv/static/theme.js") =~ ~s|localStorage.getItem("ravix.theme")|
      assert File.read!("priv/static/theme.js") =~ ~s|setAttribute("data-theme"|
      assert html =~ ~r|<title[^>]*>Ravix</title>|
      refute html =~ "data-suffix"
      assert html =~ ~s(<meta name="color-scheme" content="dark">)
      assert html =~ ~s(rel="icon")
      assert html =~ ~s(href="/assets/js/app.css")
      assert html =~ ~s(src="/assets/js/app.js")
      assert html =~ "BODY"
      refute html =~ "topbar"
    end

    test "a page title is the tab title, with no suffix" do
      html =
        Layouts.root(%{inner_content: "", page_title: "Track"})
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ ~r|<title[^>]*>Track</title>|
      refute html =~ "data-suffix"
    end

    test "the app layout is the page and its toasts, nothing else" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={%{}}>PAGE</Layouts.app>
        """)

      assert html =~ "PAGE"
      assert html =~ ~s(class="toasts")
      refute html =~ "<header"
      refute html =~ "navbar"
    end

    test "the theme hook owns the same key the layout reads" do
      js = File.read!(Path.expand("../../assets/js/hooks/theme.js", __DIR__))
      assert js =~ ~s(THEME_KEY = "ravix.theme")
    end

    test "every static file at the root is reachable once it has been digested" do
      # `mix phx.digest` renames a file at the root --- `theme.js` on disk is
      # served as `theme-<digest>.js` --- and `Plug.Static` compares `:only`
      # against the request's first segment exactly, so a digested root file
      # is not in that list and 404s. Only production rewrites the tag, so
      # only production asked for the name that was refused: the palette
      # bootstrap was a 404 there and every hard load painted the default
      # theme until LiveView connected.
      #
      # A directory is unaffected, and must stay out of the prefix list:
      # `only_matching: ["assets"]` would serve anything whose first segment
      # merely begins with it.
      roots = Enum.filter(RavixWeb.static_paths(), &(Path.extname(&1) != ""))
      prefixes = RavixWeb.static_prefixes()

      assert roots != []
      assert Enum.sort(prefixes) == Enum.sort(Enum.map(roots, &Path.rootname/1))

      for path <- RavixWeb.static_paths() -- roots do
        refute path in prefixes, "#{path} is a directory and needs no prefix"
      end

      # The shape `phx.digest` actually produces, against the rule
      # `Plug.Static` actually applies to it.
      for root <- roots do
        digested = Path.rootname(root) <> "-" <> String.duplicate("a", 32) <> Path.extname(root)
        assert Enum.any?(prefixes, &String.starts_with?(digested, &1)), "#{digested} is refused"
      end
    end
  end
end
