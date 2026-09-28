defmodule Ravix.WorkspaceSharingTest do
  @moduledoc """
  ADR 0009 phase 5: the Share dialog's context calls, the retirement of
  #299's invitations and links on workspace projects, and the cutover that
  turns legacy seats into permission rows (`Ravix.People.Cutover`).

  The switch and the creator-billing hook are stubbed per test process
  (`Ravix.Config` is Mimic-copied), so this file stays async. Access itself
  is never stubbed.
  """
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Access
  alias Ravix.People
  alias Ravix.People.{AccessNotice, Cutover}
  alias Ravix.People.Store, as: PeopleStore
  alias Ravix.Projects.Project
  alias Ravix.Tracks.{Track, TrackInvite, TrackLink, TrackMember, TrackPermission}
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Membership, Store}

  setup do
    switch(true)

    [owner, creator, colleague, holder, outsider, legacy, pending_member] =
      for login <- ~w(owner creator colleague holder outsider legacy pendingmember),
          do: insert_user(login: "#{login}#{System.unique_integer([:positive])}", name: login)

    {:ok, workspace} = Store.ensure_personal_workspace(owner)
    for user <- [creator, colleague, holder], do: member!(workspace, user)

    project = in_workspace(insert_project(user: owner, name: "Team"), workspace)
    insert_project_member(project, legacy)

    secret =
      insert_track(
        project: project,
        title: "Secret",
        visibility: :private,
        sandbox_layout: :dedicated,
        created_by: creator.id,
        created_by_login: creator.login
      )

    open =
      insert_track(
        project: project,
        title: "Open",
        created_by: creator.id,
        created_by_login: creator.login
      )

    # A project nobody moved into a workspace: legacy, whatever the switch says.
    old = insert_project(user: owner, name: "Old")

    old_track =
      insert_track(
        project: old,
        title: "Old work",
        created_by: owner.id,
        created_by_login: owner.login
      )

    %{
      owner: owner,
      creator: creator,
      colleague: colleague,
      holder: holder,
      outsider: outsider,
      legacy: legacy,
      pending_member: pending_member,
      workspace: workspace,
      project: project,
      secret: secret,
      open: open,
      old: old,
      old_track: old_track
    }
  end

  defp switch(on?), do: stub(Ravix.Config, :workspace_access?, fn -> on? end)

  defp member!(workspace, user) do
    %Membership{}
    |> Membership.changeset(%{workspace_id: workspace.id, user_id: user.id, role: :member})
    |> Repo.insert!()
  end

  defp in_workspace(project, workspace) do
    Repo.update_all(where(Project, id: ^project.id), set: [workspace_id: workspace.id])
    Repo.get!(Project, project.id)
  end

  defp reaches?(user, track), do: match?({:ok, _}, Access.track_access(user, track.id))

  # A link as #299 minted it, straight into the table: `mint_link/2` itself
  # refuses on a workspace project now.
  defp old_link(track, by) do
    token = Ravix.Crypto.random_token()
    :ok = PeopleStore.put_link(track.id, Ravix.Crypto.sha256(token), by.id, 60_000)
    token
  end

  describe "the Share dialog's view" do
    test "the creator may choose visibility and manage people on a private track", ctx do
      assert {:ok, sharing} = People.sharing(ctx.creator, ctx.secret.id)
      assert sharing.set_visibility and sharing.manage_people and sharing.private_allowed
      assert sharing.visibility == :private
      assert sharing.workspace == ctx.workspace.name
      assert sharing.url =~ "/p/#{ctx.project.id}/t/#{ctx.secret.id}"
      assert sharing.holders == []
      assert is_nil(sharing.consent)
    end

    test "a workspace member reads it but may change nothing", ctx do
      assert {:ok, sharing} = People.sharing(ctx.colleague, ctx.open.id)
      refute sharing.set_visibility
      refute sharing.manage_people
      assert sharing.visibility == :project
    end

    test "is not found for a stranger, on a legacy project, and with the switch off", ctx do
      assert {:error, :not_found} = People.sharing(ctx.outsider, ctx.open.id)
      assert {:error, :not_found} = People.sharing(ctx.owner, ctx.old_track.id)
      switch(false)
      assert {:error, :not_found} = People.sharing(ctx.creator, ctx.secret.id)
      refute People.workspace_sharing?(ctx.project)
    end
  end

  describe "the @-mention list and adding people" do
    test "offers only live members of the track's workspace, less its creator", ctx do
      assert {:ok, offered} = People.share_candidates(ctx.creator, ctx.secret.id, "@")
      logins = Enum.map(offered, & &1.login)

      assert ctx.colleague.login in logins and ctx.holder.login in logins
      assert ctx.owner.login in logins
      refute ctx.creator.login in logins
      refute ctx.outsider.login in logins
      # A legacy project member is not a workspace member, so not offered.
      refute ctx.legacy.login in logins

      assert {:ok, [only]} = People.share_candidates(ctx.creator, ctx.secret.id, "HOLDER")
      assert only.login == ctx.holder.login
      assert {:ok, []} = People.share_candidates(ctx.creator, ctx.secret.id, ctx.outsider.login)
      # A LIKE wildcard is a character, not a pattern.
      assert {:ok, []} = People.share_candidates(ctx.creator, ctx.secret.id, "%")
    end

    test "adding writes a permission row the added member can use; they drop off the list", ctx do
      refute reaches?(ctx.holder, ctx.secret)
      assert :ok = People.share_login(ctx.creator, ctx.secret.id, "@" <> ctx.holder.login)
      assert reaches?(ctx.holder, ctx.secret)
      assert {:ok, %{holders: [%{login: login}]}} = People.sharing(ctx.creator, ctx.secret.id)
      assert login == ctx.holder.login

      assert {:ok, offered} = People.share_candidates(ctx.creator, ctx.secret.id, "")
      refute ctx.holder.login in Enum.map(offered, & &1.login)
    end

    test "the server refuses anybody outside the workspace, known or not", ctx do
      for login <- [
            ctx.outsider.login,
            ctx.legacy.login,
            "nobody-here-#{System.unique_integer()}"
          ] do
        assert {:error, {:unprocessable, "not_workspace_member", message}} =
                 People.share_login(ctx.creator, ctx.secret.id, login)

        assert message =~ "not a member of this track's workspace"
      end

      refute Repo.exists?(where(TrackPermission, track_id: ^ctx.secret.id))
      refute reaches?(ctx.outsider, ctx.secret)
    end

    test "only whoever manages the private track may search or add", ctx do
      assert {:error, {:forbidden, _}} = People.share_candidates(ctx.colleague, ctx.open.id, "a")
      :ok = People.share_login(ctx.creator, ctx.secret.id, ctx.holder.login)
      assert {:error, {:forbidden, _}} = People.share_candidates(ctx.holder, ctx.secret.id, "a")

      assert {:error, {:forbidden, _}} =
               People.share_login(ctx.holder, ctx.secret.id, ctx.colleague.login)

      assert {:error, :not_found} = People.share_candidates(ctx.outsider, ctx.secret.id, "a")
      # A workspace-visible track reaches everybody already.
      assert {:error, {:unprocessable, "not_private", _}} =
               People.share_candidates(ctx.owner, ctx.open.id, "a")
    end

    test "removing deletes the row and access; a holder may leave", ctx do
      :ok = People.share_login(ctx.creator, ctx.secret.id, ctx.holder.login)
      :ok = People.share_login(ctx.creator, ctx.secret.id, ctx.colleague.login)

      assert :ok = People.unshare_login(ctx.creator, ctx.secret.id, "@" <> ctx.holder.login)
      refute reaches?(ctx.holder, ctx.secret)
      assert :ok = People.unshare_login(ctx.colleague, ctx.secret.id, ctx.colleague.login)
      refute reaches?(ctx.colleague, ctx.secret)
      refute Repo.exists?(where(TrackPermission, track_id: ^ctx.secret.id))

      assert {:error, :not_found} = People.unshare_login(ctx.outsider, ctx.secret.id, "x")
    end
  end

  describe "the creator's consent (RAV-17)" do
    defp creator_billed(track, payer) do
      Repo.update_all(where(Track, id: ^track.id),
        set: [billing_policy: :creator, payer_user_id: payer.id]
      )
    end

    test "is not asked on a track its creator does not pay for", ctx do
      assert {:ok, %{consent: nil}} = People.sharing(ctx.creator, ctx.secret.id)
      :ok = People.share_login(ctx.creator, ctx.secret.id, ctx.holder.login)
      assert :ok = People.consent_sharing(ctx.creator, ctx.secret.id)
      assert is_nil(Repo.get!(Track, ctx.secret.id).billing_notice_at)
    end

    test "shows until the creator's first share, and once only, on the track page's column",
         ctx do
      creator_billed(ctx.secret, ctx.creator)
      creator_billed(ctx.open, ctx.creator)

      assert {:ok, %{consent: "Collaborators' prompts here use your " <> _}} =
               People.sharing(ctx.creator, ctx.secret.id)

      # Nobody else is asked about the creator's subscription.
      assert {:ok, %{consent: nil}} = People.sharing(ctx.colleague, ctx.open.id)
      :ok = People.consent_sharing(ctx.colleague, ctx.open.id)
      assert is_nil(Repo.get!(Track, ctx.open.id).billing_notice_at)

      :ok = People.share_login(ctx.creator, ctx.secret.id, ctx.holder.login)
      at = Repo.get!(Track, ctx.secret.id).billing_notice_at
      assert %DateTime{} = at
      assert {:ok, %{consent: nil}} = People.sharing(ctx.creator, ctx.secret.id)
      # The track page's copy of the note has been shown too.
      assert {:ok, nil} = Ravix.Tracks.billing_notice(ctx.creator, ctx.secret.id)

      :ok = People.consent_sharing(ctx.creator, ctx.secret.id)
      assert Repo.get!(Track, ctx.secret.id).billing_notice_at == at
    end
  end

  describe "invitations and links on a workspace project, with the switch on" do
    test "no invitation by login and no new link; an existing one reads as none", ctx do
      assert {:error, {:unprocessable, "workspace_sharing", _}} =
               People.add(ctx.owner, ctx.open.id, ctx.outsider.login)

      assert {:error, {:unprocessable, "workspace_sharing", _}} =
               People.mint_link(ctx.creator, ctx.secret.id)

      old_link(ctx.secret, ctx.creator)
      assert {:ok, nil} = People.link(ctx.creator, ctx.secret.id)
    end

    test "an old link admits nobody, whoever holds it", ctx do
      token = old_link(ctx.secret, ctx.creator)

      for user <- [ctx.outsider, ctx.colleague] do
        assert People.link_target(token, user) == :retired
        assert People.claim_link(user.id, token) == :retired
        refute reaches?(user, ctx.secret)
      end

      refute Repo.exists?(where(TrackMember, track_id: ^ctx.secret.id))
    end

    test "an invitation waiting at sign-in is dropped, not honoured", ctx do
      insert_track_invite(ctx.secret,
        github_id: ctx.outsider.github_id,
        login: ctx.outsider.login,
        invited_by: ctx.creator.id
      )

      assert %{tracks: []} = PeopleStore.claim_invites(ctx.outsider.id, ctx.outsider.github_id)
      refute reaches?(ctx.outsider, ctx.secret)
      refute Repo.exists?(where(TrackInvite, track_id: ^ctx.secret.id))
    end

    test "a legacy project keeps its links and invitations", ctx do
      assert {:ok, %{url: url}} = People.mint_link(ctx.owner, ctx.old_track.id)
      token = url |> String.split("/j/") |> List.last()
      assert {:ok, _} = People.link_target(token)
      assert {:ok, _} = People.claim_link(ctx.outsider.id, token)
      assert reaches?(ctx.outsider, ctx.old_track)
    end

    test "with the switch off a workspace project keeps today's links", ctx do
      switch(false)
      assert {:ok, %{url: url}} = People.mint_link(ctx.creator, ctx.secret.id)
      token = url |> String.split("/j/") |> List.last()
      assert {:ok, _} = People.claim_link(ctx.outsider.id, token)
      assert reaches?(ctx.outsider, ctx.secret)
    end
  end

  describe "the cutover" do
    setup ctx do
      # Seats as #299 left them: a workspace member and an outsider on the
      # private track; a legacy project member and an outsider on the open one.
      insert_track_member(ctx.secret, ctx.holder)
      insert_track_member(ctx.secret, ctx.outsider)
      insert_track_member(ctx.open, ctx.legacy)
      insert_track_member(ctx.open, ctx.pending_member)

      insert_track_invite(ctx.secret,
        github_id: "gh-#{System.unique_integer([:positive])}",
        login: "notyethere",
        invited_by: ctx.creator.id
      )

      token = old_link(ctx.secret, ctx.creator)
      old_token = old_link(ctx.old_track, ctx.owner)
      insert_track_member(ctx.old_track, ctx.outsider)

      # Before the cutover the seats still admit.
      assert reaches?(ctx.outsider, ctx.secret)
      %{token: token, old_token: old_token}
    end

    test "is refused while the switch is off", _ctx do
      switch(false)
      assert {:error, :switch_off} = Cutover.run(apply: true)
    end

    test "a dry run plans it and writes nothing", ctx do
      assert {:ok, %{applied: false, tracks: tracks}} = Cutover.run()
      secret = Enum.find(tracks, &(&1.track_id == ctx.secret.id))

      assert secret.converted == [ctx.holder.login]
      assert secret.revoked == [ctx.outsider.login]
      assert secret.withdrawn == ["notyethere"]
      assert secret.link

      open = Enum.find(tracks, &(&1.track_id == ctx.open.id))
      assert open.revoked == [ctx.pending_member.login]
      # A legacy project member keeps an open track through the project.
      assert open.converted == []

      refute Enum.any?(tracks, &(&1.track_id == ctx.old_track.id))

      assert Repo.aggregate(where(TrackMember, track_id: ^ctx.secret.id), :count) == 2
      assert Repo.exists?(where(TrackLink, track_id: ^ctx.secret.id))
      refute Repo.exists?(AccessNotice)
      assert reaches?(ctx.outsider, ctx.secret)

      text = Enum.join(Cutover.format(%{applied: false, tracks: tracks}), "\n")
      assert text =~ "Dry run"
      assert text =~ "@#{ctx.outsider.login}"
    end

    test "converts members, revokes the rest, retires links and notes it once", ctx do
      assert {:ok, %{applied: true}} = Cutover.run(apply: true)

      # The workspace member keeps the track, on a permission row now.
      assert reaches?(ctx.holder, ctx.secret)

      assert Repo.exists?(
               where(TrackPermission, track_id: ^ctx.secret.id, user_id: ^ctx.holder.id)
             )

      refute Repo.exists?(where(TrackMember, track_id: ^ctx.secret.id))

      # Nobody outside the workspace keeps anything, and nobody joined it.
      refute reaches?(ctx.outsider, ctx.secret)
      refute reaches?(ctx.pending_member, ctx.open)
      assert reaches?(ctx.legacy, ctx.open)
      assert is_nil(Store.membership(ctx.workspace.id, ctx.outsider.id))
      assert is_nil(Store.membership(ctx.workspace.id, ctx.legacy.id))

      refute Repo.exists?(where(TrackLink, track_id: ^ctx.secret.id))
      refute Repo.exists?(where(TrackInvite, track_id: ^ctx.secret.id))
      assert People.claim_link(ctx.outsider.id, ctx.token) == :error

      # A legacy project is untouched.
      assert reaches?(ctx.outsider, ctx.old_track)
      assert {:ok, _} = People.link_target(ctx.old_token)

      assert [secret_note, open_note] =
               ctx.creator |> People.notices() |> Enum.sort_by(&(&1.track_id != ctx.secret.id))

      assert secret_note.track_id == ctx.secret.id
      assert secret_note.revoked == [ctx.outsider.login]
      assert secret_note.withdrawn == ["notyethere"]
      assert secret_note.workspace_id == ctx.workspace.id
      assert open_note.revoked == [ctx.pending_member.login]
      assert People.notices(ctx.holder) == []

      # Safe to run again: nothing left, and no second note.
      assert {:ok, %{tracks: []}} = Cutover.run(apply: true)
      assert Repo.aggregate(AccessNotice, :count) == 2
    end

    test "a converted holder loses the track when they leave the workspace", ctx do
      {:ok, _} = Cutover.run(apply: true)
      assert reaches?(ctx.holder, ctx.secret)

      :ok = Workspaces.remove_member(ctx.owner, ctx.workspace.id, ctx.holder.id)
      refute reaches?(ctx.holder, ctx.secret)
    end

    test "a closed track's seats and links go, without a note", ctx do
      Repo.update_all(where(Track, id: ^ctx.secret.id), set: [closed_at: DateTime.utc_now()])
      {:ok, _} = Cutover.run(apply: true)

      refute Repo.exists?(where(TrackMember, track_id: ^ctx.secret.id))
      refute Repo.exists?(where(AccessNotice, track_id: ^ctx.secret.id))
    end

    test "notes are the recipient's to dismiss, and nobody else's", ctx do
      {:ok, _} = Cutover.run(apply: true)
      [note | _] = People.notices(ctx.creator)

      assert {:error, :not_found} = People.dismiss_notice(ctx.holder, note.id)
      assert :ok = People.dismiss_notice(ctx.creator, note.id)
      refute Enum.any?(People.notices(ctx.creator), &(&1.id == note.id))
      assert {:error, :not_found} = People.dismiss_notice(ctx.creator, note.id)
    end
  end
end
