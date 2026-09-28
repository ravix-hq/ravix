defmodule RavixWeb.RetiredLinkTest do
  @moduledoc """
  ADR 0009 phase 5 and RAV-32: an old track or project invite link after
  workspace sharing replaced them. With `RAVIX_WORKSPACE_ACCESS` on,
  `GET /j/:token` says to ask the project's owner for a workspace invitation
  and `POST` admits nobody; with it off, today's links work as they did.
  Real rows throughout; the switch is stubbed.
  """
  use RavixWeb.ConnCase, async: true
  import Mimic
  import Ecto.Query, only: [where: 2]

  alias Ravix.Accounts.Access
  alias Ravix.Projects.{Project, ProjectMember}
  alias Ravix.Repo
  alias Ravix.Tracks.TrackMember
  alias Ravix.Workspaces.Store

  setup do
    stub(Ravix.Config, :workspace_access?, fn -> true end)

    owner = insert_user()
    outsider = insert_user()
    {:ok, workspace} = Store.ensure_personal_workspace(owner)
    project = insert_project(user: owner, name: "Team")
    Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: workspace.id])

    track =
      insert_track(project: project, created_by: owner.id, created_by_login: owner.login)

    {token, _link} = insert_track_link(track, created_by: owner.id)
    {project_token, _link} = insert_project_link(project, created_by: owner.id)

    %{
      owner: owner,
      outsider: outsider,
      project: project,
      track: track,
      token: token,
      project_token: project_token
    }
  end

  test "the link page asks for the creator instead of offering to join", ctx do
    conn = log_in_user(build_conn(), ctx.outsider)
    html = html_response(get(conn, "/j/#{ctx.token}"), 410)

    assert html =~ "This invite link no longer works"
    assert html =~ "Ask the project's owner for an invitation to its workspace."
    refute html =~ ctx.track.title
    refute html =~ ~s(method="post")
  end

  test "posting the link admits nobody", ctx do
    conn = log_in_user(build_conn(), ctx.outsider)
    assert html_response(post(conn, "/j/#{ctx.token}"), 410) =~ "no longer works"

    refute Repo.exists?(where(TrackMember, track_id: ^ctx.track.id))
    assert {:error, :not_found} = Access.track_access(ctx.outsider, ctx.track.id)
  end

  test "a link the cutover deleted reads the same as one that never was", ctx do
    conn = log_in_user(build_conn(), ctx.outsider)
    assert html_response(get(conn, "/j/never-minted"), 410) =~ "Ask the project's owner"
  end

  test "a project link reads the same page and admits nobody", ctx do
    conn = log_in_user(build_conn(), ctx.outsider)
    html = html_response(get(conn, "/j/#{ctx.project_token}"), 410)

    assert html =~ "This invite link no longer works"
    assert html =~ "Ask the project's owner for an invitation to its workspace."
    refute html =~ ctx.project.name
    refute html =~ ~s(method="post")

    assert html_response(post(conn, "/j/#{ctx.project_token}"), 410) =~ "no longer works"
    refute Repo.exists?(where(ProjectMember, project_id: ^ctx.project.id))
    assert {:error, :not_found} = Access.project_access(ctx.outsider, ctx.project.id)
  end

  test "a revoked session cannot claim a project link", ctx do
    {session_token, session} = insert_session(ctx.outsider)
    conn = Plug.Test.init_test_session(build_conn(), session_token: session_token)
    Repo.delete!(session)
    app = Ravix.GitHubFake.app()
    stub(Ravix.Config, :github, fn -> app end)

    # Signed out: sent round the sign-in trip, nothing written.
    assert redirected_to(post(conn, "/j/#{ctx.project_token}"), 303) =~ "/login/oauth/authorize?"
    refute Repo.exists?(where(ProjectMember, project_id: ^ctx.project.id))
  end

  test "with the switch off the link still joins", ctx do
    stub(Ravix.Config, :workspace_access?, fn -> false end)
    conn = log_in_user(build_conn(), ctx.outsider)

    assert html_response(get(conn, "/j/#{ctx.token}"), 200) =~ "Join this track"
    assert redirected_to(post(conn, "/j/#{ctx.token}"), 303) =~ ctx.track.id
    assert {:ok, _} = Access.track_access(ctx.outsider, ctx.track.id)
    assert redirected_to(get(conn, "/j/never-minted"), 303) == "/?error=bad_invite"
  end

  test "with the switch off a project link still joins", ctx do
    stub(Ravix.Config, :workspace_access?, fn -> false end)
    conn = log_in_user(build_conn(), ctx.outsider)

    assert html_response(get(conn, "/j/#{ctx.project_token}"), 200) =~ ctx.project.name
    assert redirected_to(post(conn, "/j/#{ctx.project_token}"), 303) == "/p/#{ctx.project.id}"
    assert {:ok, _} = Access.project_access(ctx.outsider, ctx.project.id)
  end
end
