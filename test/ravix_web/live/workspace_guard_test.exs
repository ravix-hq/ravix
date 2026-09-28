defmodule RavixWeb.Live.WorkspaceGuardTest do
  @moduledoc """
  ADR 0009 phase 3a: removing a workspace member reaches a page that is
  already open, whether the removal notice arrives or not.
  """
  use RavixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ravix.Repo
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Membership, Store}
  alias RavixWeb.Live.Guard
  alias RavixWeb.WorkspaceGuardFixtureLive, as: Page

  setup %{conn: conn} do
    owner = insert_user()
    member = insert_user()
    workspace = Store.ensure_personal_workspace(owner)

    Repo.insert!(%Membership{
      workspace_id: workspace.id,
      user_id: member.id,
      role: :member,
      created_at: DateTime.utc_now()
    })

    %{conn: log_in_user(conn, member), owner: owner, member: member, workspace: workspace}
  end

  defp open(ctx) do
    live_isolated(ctx.conn, Page,
      session: %{"workspace_id" => ctx.workspace.id, "test" => self()}
    )
  end

  # A removal whose notice never arrives: the lost-PubSub case.
  defp revoke_silently(ctx),
    do: {:ok, _} = Store.revoke_membership(ctx.workspace.id, ctx.member.id, :owner)

  test "a member's page holds the workspace; a stranger's and another tenant's do not", ctx do
    {:ok, view, _html} = open(ctx)
    assert view |> element("#role") |> render() =~ "member"
    assert render_click(view, "ping") =~ ~s(<p id="pings">1</p>)

    stranger = log_in_user(build_conn(), insert_user())
    session = %{"workspace_id" => ctx.workspace.id, "test" => self()}
    assert {:error, {:redirect, %{to: "/"}}} = live_isolated(stranger, Page, session: session)

    elsewhere = Store.ensure_personal_workspace(insert_user())
    session = %{"workspace_id" => elsewhere.id, "test" => self()}
    assert {:error, {:redirect, %{to: "/"}}} = live_isolated(ctx.conn, Page, session: session)
  end

  test "removal sends an open page home on the notice, with nothing else to prompt it", ctx do
    {:ok, view, _html} = open(ctx)

    assert :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.member.id)
    assert_redirect(view, "/")
  end

  test "a notice about another workspace does not reach the page or send it anywhere", ctx do
    {:ok, view, _html} = open(ctx)
    send(view.pid, {:workspace_hub, Ecto.UUID.generate(), :members})
    send(view.pid, {:workspace_hub, ctx.workspace.id, :members})
    send(view.pid, :ping)

    assert view |> element("#pings") |> render() =~ ">1<"
  end

  test "an event after a removal whose notice was lost is refused", ctx do
    {:ok, view, _html} = open(ctx)
    revoke_silently(ctx)

    assert {:error, {:redirect, %{to: "/"}}} = render_click(view, "ping")
  end

  test "a stale async result is dropped, even when it beats the notice", ctx do
    {:ok, view, _html} = open(ctx)
    render_click(view, "load")
    assert_receive {:loading, task}

    revoke_silently(ctx)
    ref = Process.monitor(view.pid)
    send(task, {:release, "private sibling names"})

    assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, {:redirect, %{to: "/"}}}}
  end

  test "an async result for a member who stayed is applied", ctx do
    {:ok, view, _html} = open(ctx)
    render_click(view, "load")
    assert_receive {:loading, task}
    send(task, {:release, "still yours"})

    assert render_async(view) =~ "still yours"
  end

  test "a lost notice still ends the held answer on the backstop", ctx do
    {:ok, view, _html} = open(ctx)
    revoke_silently(ctx)

    # Within the backstop a message goes through on the held answer...
    send(view.pid, :ping)
    assert view |> element("#pings") |> render() =~ ">1<"

    # ...and once it has run out, the next message re-reads and leaves.
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.workspace_guard, &Guard.stale/1)
    end)

    ref = Process.monitor(view.pid)
    send(view.pid, :ping)
    assert_receive {:DOWN, ^ref, :process, _pid, {:shutdown, {:redirect, %{to: "/"}}}}
  end
end
