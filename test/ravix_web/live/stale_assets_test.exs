defmodule RavixWeb.Live.StaleAssetsTest do
  @moduledoc """
  A tab holding an earlier release's CSS and JS is told so and offered a
  reload it presses itself (RAV-138); a tab holding the current ones is not.

  `browser/stale-assets.spec.js` stages the same against a digested build.
  """
  use RavixWeb.ConnCase, async: false

  # `async: false`: the digest manifest is the endpoint's, and every test
  # running at once reads it.

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias RavixWeb.Endpoint
  alias RavixWeb.Live.StaleAssets

  @latest %{
    "assets/js/app.css" => "assets/js/app-1f2e3d4c.css",
    "assets/js/app.js" => "assets/js/app-5a6b7c8d.js"
  }
  @current [
    "http://localhost/assets/js/app-1f2e3d4c.css?vsn=d",
    "http://localhost/assets/js/app-5a6b7c8d.js?vsn=d"
  ]
  @stale [
    "http://localhost/assets/js/app-0000aaaa.css?vsn=d",
    "http://localhost/assets/js/app-0000bbbb.js?vsn=d"
  ]

  setup do
    previous = Endpoint.config(:cache_static_manifest_latest)
    Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, @latest)
    on_exit(fn -> Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, previous) end)
  end

  defp statics(conn, statics), do: put_connect_params(conn, %{"_track_static" => statics})

  test "a page whose tracked assets this release does not serve shows the reload bar, and nothing reloads by itself",
       %{conn: conn} do
    {:ok, view, _html} = live(statics(conn, @stale), "/login?return=deploy")

    assert render(element(view, "#reload-bar[role=status]")) =~ "Ravix was updated."
    assert has_element?(view, ~s(#reload-bar button[type=button]), "Reload")
    # Still the page: it was not redirected on the way in.
    assert render(view) =~ "Sign in"
  end

  test "Reload sends the page through a page load of the URL it is on", %{conn: conn} do
    {:ok, view, _html} = live(statics(conn, @stale), "/login?return=deploy")

    assert {:error, {:redirect, %{to: "/login?return=deploy"}}} =
             view |> element("#reload-bar button") |> render_click()
  end

  test "the onboarding pages show it too", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    {:ok, view, _html} = live(statics(conn, @stale), "/welcome")

    assert has_element?(view, "#reload-bar")

    assert {:error, {:redirect, %{to: "/welcome"}}} =
             view |> element("#reload-bar button") |> render_click()
  end

  test "a page whose tracked assets are current has no bar", %{conn: conn} do
    {:ok, view, _html} = live(statics(conn, @current), "/login")

    refute has_element?(view, "#reload-bar")
  end

  test "a build without a digest manifest never shows it", %{conn: conn} do
    Phoenix.Config.put(Endpoint, :cache_static_manifest_latest, nil)
    {:ok, view, _html} = live(statics(conn, @stale), "/login")

    refute has_element?(view, "#reload-bar")
  end

  test "a nested LiveView is never asked, and is never stale" do
    assert {:cont, socket} =
             StaleAssets.on_mount(:default, %{}, %{}, %Socket{
               endpoint: Endpoint,
               parent_pid: self()
             })

    assert socket.assigns.static_changed? == false
  end
end
