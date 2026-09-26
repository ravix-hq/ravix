defmodule RavixWeb.WorkspaceRefsTest do
  use RavixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mimic

  alias Ravix.GitHubFake, as: GH
  alias Ravix.Tracks

  setup :verify_on_exit!

  setup %{conn: conn} do
    app = GH.app()
    stub(Ravix.Config, :github, fn -> app end)
    user = insert_user()
    project = insert_project(user: user)
    {:ok, view, _} = live(log_in_user(conn, user), "/p/#{project.id}")
    render_click(view, "dialog", %{name: "new-track"})
    view |> element("button[phx-click=advanced-track]") |> render_click()
    %{app: app, project: project, user: user, view: view}
  end

  for {kind, endpoint, raw, value, label, origin} <- [
        {"branch", "branches", %{name: "release", commit: %{sha: "abc"}}, "release", "release",
         %{kind: "branch", base: "release"}},
        {"pr", "pulls", %{number: 12, title: "Fix", head: %{ref: "feature/fix"}}, "12", "#12 Fix",
         %{kind: "pr", number: 12, title: "Fix", base: "feature/fix"}},
        {"issue", "issues", %{number: 34, title: "Bug", labels: []}, "34", "#34 Bug",
         %{kind: "issue", number: 34, title: "Bug"}}
      ],
      outcome <- [:success, :error] do
    @kind kind
    @endpoint endpoint
    @raw raw
    @value value
    @label label
    @origin origin
    @outcome outcome

    test "#{kind} refs keep the dialog open on #{outcome}", ctx do
      owner = self()

      GH.install([
        GH.token_route(ctx.app),
        {"GET", "/repos/#{ctx.project.repo_full_name}/#{@endpoint}",
         fn conn ->
           send(owner, {:loading_refs, self()})

           receive do
             :finish ->
               case @outcome do
                 :success ->
                   Req.Test.json(conn, [@raw])

                 :error ->
                   conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{message: "Refs denied"})
               end
           end
         end}
      ])

      ctx.view |> element("button[phx-click=origin][phx-value-kind=#{@kind}]") |> render_click()
      # This handshake includes installation-token signing and provider setup;
      # the default 100ms is too short on a busy CI runner.
      assert_receive {:loading_refs, task}, 5_000
      assert has_element?(ctx.view, "#new-track-form [role=status]", "Loading branches")
      assert has_element?(ctx.view, "#track-ref[disabled]")
      send(task, :finish)
      html = render_async(ctx.view)
      assert has_element?(ctx.view, "#new-track-form")
      refute has_element?(ctx.view, "#new-track-form [role=status]")
      refute has_element?(ctx.view, "#track-ref[disabled]")

      if @outcome == :success do
        assert has_element?(ctx.view, "#track-ref option[value='#{@value}']", @label)

        expect(Tracks, :open, fn user, id, attrs ->
          assert {user.id, id} == {ctx.user.id, ctx.project.id}
          assert attrs.origin == @origin
          {:error, {:unavailable, "Machine unavailable"}}
        end)

        ctx.view |> form("#new-track-form", new_track: [ref: @value]) |> render_submit()
        assert render_async(ctx.view) =~ "Machine unavailable"
        assert has_element?(ctx.view, "#new-track-form")
      else
        assert html =~ "Refs denied"
        assert has_element?(ctx.view, "#new-track-form button[disabled]", "Create track")
      end
    end
  end
end
