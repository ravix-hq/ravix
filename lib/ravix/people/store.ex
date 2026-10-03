defmodule Ravix.People.Store do
  @moduledoc """
  The membership rows, with nobody's permission established.

  Every function here takes ids and touches the table. None of them asks who
  is calling, and none of them may be reached from a page. That is the whole
  of the contract, and it is a module boundary because it used to be a
  comment: these lived at the bottom of `Ravix.People` under a divider that
  said "treat every function below as unscoped", beside the scoped routes
  that share their names. `Ravix.People.drop_link/2` refused anyone but the
  owner; `Ravix.People.drop_link/1`, forty lines down the same file, refused
  nobody. Nothing could catch the wrong one being called, because to the
  compiler they were one module's two arities.

  Now the caller has to say `Store.` to get the unchecked one, and
  `Ravix.Credo.Architecture` fails the build if that caller is in
  `lib/ravix_web/` or is another context reaching in without a
  `# ownership:` comment naming the door it went through first.

  The legitimate callers are `Ravix.People` itself, which establishes access
  through `Ravix.Accounts.Access` before every one of these; `Access`, whose
  two membership questions *are* two of these reads; the sign-in that claims
  invitations before the person has any access to establish; and the track
  and project lists, which read seats and read-markers for people they have
  already been let in to see.
  """

  @typedoc "How this person comes to be in the list; see `Ravix.People.Person`."
  @type via :: Ravix.People.Person.via()

  @typedoc "A GitHub account, with no claim about access; see `Ravix.People.Profile`."
  @type profile :: Ravix.People.Profile.t()

  @typedoc "Somebody in a people list; see `Ravix.People.Person`."
  @type person :: Ravix.People.Person.t()

  @typedoc "An invitation waiting on a track or a project; see `Ravix.People.Invite`."
  @type invite :: Ravix.People.Invite.t()

  import Ecto.Query

  alias Ravix.Accounts.User
  alias Ravix.People.{AccessNotice, Invite, Person, Profile}
  alias Ravix.Projects.{Project, ProjectInvite, ProjectLink, ProjectMember}
  alias Ravix.Projects.Store, as: Projects
  alias Ravix.Repo
  alias Ravix.Tracks.Store, as: Tracks
  alias Ravix.Tracks.{Track, TrackInvite, TrackLink, TrackMember, TrackPermission, TrackRead}

  # ── who else is in a track ─────────────────────────────────────

  @doc "Seat `user_id` on a track. A second seat for the same person is not two seats."
  @spec add_member(String.t(), String.t(), String.t()) :: :ok
  def add_member(track_id, user_id, invited_by) do
    %TrackMember{}
    |> TrackMember.changeset(%{track_id: track_id, user_id: user_id, invited_by: invited_by})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:track_id, :user_id])

    :ok
  end

  @doc """
  Take `user_id` off a track, and with it every preview grant they held
  on it, so a browser tab they left open stops working with the row.

  The hub is told here rather than by the caller. This is the function that
  takes the access away, and a page holding the answer "yes, they may read
  this track" finds out it has changed by hearing `:people` on the project
  -- so the announcement belongs to the revocation and not to whichever of
  the routes above happened to ask for it. One caller forgetting would be a
  transcript still streaming to somebody who was removed from it.
  """
  @spec remove_member(String.t(), String.t()) :: :ok
  def remove_member(track_id, user_id) do
    # ownership: `Ravix.People.remove/3` admitted the caller through
    # `Access.track_access/2`. The seat being deleted below names this track
    # and this person, and their preview grants on it are part of what it gave.
    Ravix.Previews.Store.revoke(track_id, user_id)
    Ravix.Previews.Store.revoke_agent(track_id, user_id)

    Repo.delete_all(
      from(m in TrackMember, where: m.track_id == ^track_id and m.user_id == ^user_id)
    )

    # ownership: `Ravix.People.remove/3` admitted the caller through
    # `Access.track_access/2` on this track before taking the seat away, and
    # the seat named the track. Read only to learn which project's hub to tell.
    case Tracks.get_track(track_id) do
      %Track{project_id: project_id} -> Ravix.Hub.publish(project_id, :people, track_id: track_id)
      nil -> :ok
    end

    :ok
  end

  # ── workspace permission rows (ADR 0009) ─────────────────────────────

  @doc """
  Share a private track with `user_id` under `workspace_id`, only while they
  are a live member of it. Idempotent. The caller has established that the
  track is the creator's, private and in that workspace.

  The membership is read `FOR SHARE` in the insert's transaction, which is
  what keeps a concurrent removal from leaving a fresh row behind: the
  removal's `FOR UPDATE` (`Ravix.Workspaces.Store.revoke_membership/3`)
  either waits for this share to commit and then deletes it, or has already
  committed, in which case this read finds the membership revoked and
  inserts nothing.
  """
  @spec add_permission(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_workspace_member}
  def add_permission(track_id, user_id, workspace_id, granted_by) do
    # ownership: `Ravix.People.share/3` went through `Access.track_access/2` and
    # `Access.workspace_grant/3`; the membership locked inside is the target's.
    Repo.transaction(fn ->
      # ownership: `Ravix.People.share/3` admitted the creator through
      # `Access.track_access/2` and `Access.workspace_grant/3`; this locks the
      # target's own membership, which is what the row depends on.
      live =
        Repo.one(
          from m in Ravix.Workspaces.Membership,
            where:
              m.workspace_id == ^workspace_id and m.user_id == ^user_id and
                is_nil(m.revoked_at),
            lock: "FOR SHARE"
        )

      if is_nil(live), do: Repo.rollback(:not_workspace_member)

      %TrackPermission{}
      |> TrackPermission.changeset(%{
        track_id: track_id,
        user_id: user_id,
        workspace_id: workspace_id,
        granted_by_user_id: granted_by
      })
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:track_id, :user_id])
    end)
    |> case do
      {:ok, _row} -> :ok
      {:error, :not_workspace_member} = refused -> refused
    end
  end

  @doc """
  Take a permission row away and, only if there was one, every preview
  grant its holder had on the track, then tell the project's hub -- as
  `remove_member/2` does for a legacy seat, and for the same reason. A
  person here through a legacy seat keeps that seat and its grants.
  """
  @spec remove_permission(Track.t(), String.t()) :: :ok
  def remove_permission(%Track{} = track, user_id) do
    {deleted, _} =
      Repo.delete_all(
        from(p in TrackPermission, where: p.track_id == ^track.id and p.user_id == ^user_id)
      )

    if deleted > 0 do
      # ownership: `Ravix.People.unshare/3` admitted the caller through
      # `Access.track_access/2`; the deleted row gave these grants.
      Ravix.Previews.Store.revoke(track.id, user_id)
      Ravix.Previews.Store.revoke_agent(track.id, user_id)
      Ravix.Hub.publish(track.project_id, :people, track_id: track.id)
    end

    :ok
  end

  @doc """
  Whether `user_id` holds a permission row on `track_id` under
  `workspace_id`. Only the row: whether it *counts* (the switch, a live
  membership) is `Ravix.Accounts.Access`'s question.
  """
  @spec permitted?(String.t(), String.t(), String.t()) :: boolean()
  def permitted?(track_id, user_id, workspace_id) do
    Repo.exists?(
      from(p in TrackPermission,
        where:
          p.track_id == ^track_id and p.user_id == ^user_id and p.workspace_id == ^workspace_id
      )
    )
  end

  @doc """
  The permission holders on each of `track_ids` who are still live members
  of `workspace_id`, keyed by track id. A track with none is absent.
  """
  @spec permitted_by_track([String.t()], String.t()) :: %{String.t() => [User.t()]}
  def permitted_by_track([], _workspace_id), do: %{}

  def permitted_by_track(track_ids, workspace_id) do
    # ownership: `Access.workspace_audience/2` asks, for tracks admitted by
    # `Access.track_access/2` or `Access.open_tracks/2`; the membership join
    # keeps only holders still in the workspace.
    Repo.all(
      from(p in TrackPermission,
        join: m in Ravix.Workspaces.Membership,
        on: m.workspace_id == p.workspace_id and m.user_id == p.user_id and is_nil(m.revoked_at),
        join: u in assoc(p, :user),
        where: p.track_id in ^track_ids and p.workspace_id == ^workspace_id,
        order_by: p.created_at,
        select: {p.track_id, u}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "Whether anybody holds a permission row on `track_id`."
  @spec permitted_any?(String.t()) :: boolean()
  def permitted_any?(track_id),
    do: Repo.exists?(from(p in TrackPermission, where: p.track_id == ^track_id))

  @doc "Whom a track is shared with through permission rows, oldest first."
  @spec permitted_on(String.t()) :: [User.t()]
  def permitted_on(track_id) do
    Repo.all(
      from(p in TrackPermission,
        join: u in assoc(p, :user),
        where: p.track_id == ^track_id,
        order_by: p.created_at,
        select: u
      )
    )
  end

  @doc "Whether `user_id` was named on this track. The owner is not: they own the project."
  @spec member?(String.t(), String.t()) :: boolean()
  def member?(track_id, user_id), do: seated?(TrackMember, :track_id, track_id, user_id)

  @typedoc "A role on a seat (ADR 0010); a row from before roles reads as `:write`."
  @type level :: :read | :write | :admin

  @doc "The role `user_id` holds on this track's seat, or nil with no seat."
  @spec member_role(String.t(), String.t()) :: level() | nil
  def member_role(track_id, user_id), do: seat_role(TrackMember, :track_id, track_id, user_id)

  @doc "The role `user_id` holds in the whole project, or nil when they are not in it."
  @spec project_member_role(String.t(), String.t()) :: level() | nil
  def project_member_role(project_id, user_id),
    do: seat_role(ProjectMember, :project_id, project_id, user_id)

  @doc "Every seat's role on a track, by login, for the people list."
  @spec member_roles(String.t()) :: %{String.t() => level()}
  def member_roles(track_id), do: seat_roles(TrackMember, :track_id, track_id)

  @doc """
  Change the role on `user_id`'s seat. False when there is no seat to change.
  The hub is told here, as `remove_member/2` tells it: a page holding what
  this person may do re-reads on `:people`.
  """
  @spec set_member_role(String.t(), String.t(), level()) :: boolean()
  def set_member_role(track_id, user_id, role) do
    changed? = set_seat_role(TrackMember, :track_id, track_id, user_id, role)

    # ownership: `Ravix.People.set_role/4` admitted the caller through
    # `Access.track_access/3` as an admin of this track; the row is read only
    # to learn which project's hub to tell.
    with true <- changed?,
         %Track{project_id: project_id} <- Tracks.get_track(track_id),
         do: Ravix.Hub.publish(project_id, :people, track_id: track_id)

    changed?
  end

  @doc "Change a project member's role. False when they are not a member."
  @spec set_project_member_role(String.t(), String.t(), level()) :: boolean()
  def set_project_member_role(project_id, user_id, role) do
    changed? = set_seat_role(ProjectMember, :project_id, project_id, user_id, role)
    if changed?, do: Ravix.Hub.publish(project_id, :people)
    changed?
  end

  @doc """
  Every project membership and its role, oldest first: the direct grants
  `Ravix.Accounts.Access.project_people/2` decides from.
  """
  @spec project_grants(String.t()) :: [{User.t(), level()}]
  def project_grants(project_id) do
    {users, roles} = project_seats(project_id)
    Enum.map(users, &{&1, Map.fetch!(roles, &1.login)})
  end

  @doc "Every seat on a track and its role, oldest first."
  @spec track_grants(String.t()) :: [{User.t(), level()}]
  def track_grants(track_id) do
    Repo.all(
      from(m in TrackMember,
        join: u in assoc(m, :user),
        where: m.track_id == ^track_id,
        order_by: m.created_at,
        select: {u, m.role}
      )
    )
    |> Enum.map(fn {u, role} -> {u, role || :write} end)
  end

  @doc """
  A direct grant on a workspace project for one of its workspace's live
  members (RAV-75): their project role, which takes precedence over the
  workspace's default whether it is higher or lower. Writes the membership
  if there is none, and changes its role if there is. Unlike
  `add_project_member/3` it leaves their track seats alone: on a workspace
  project a seat and a project grant answer different questions (ADR 0009).

  The membership is read `FOR SHARE` in the insert's transaction, as
  `add_permission/4` reads it, so a concurrent workspace removal
  (`Ravix.Workspaces.Store.revoke_membership/3`, which deletes these rows)
  either waits for this grant and deletes it, or has already committed and
  this writes nothing. The hub is told on success.
  """
  @spec grant_project_role(Project.t(), String.t(), level(), String.t()) ::
          :ok | {:error, :not_workspace_member}
  def grant_project_role(
        %Project{workspace_id: workspace_id} = project,
        user_id,
        role,
        granted_by
      )
      when is_binary(workspace_id) and role in [:read, :write, :admin] do
    # ownership: `Ravix.People.set_project_role/4` admitted the caller through
    # `Access.project_access/3` as an admin of this project; the membership
    # locked inside is the target's own, which is what the grant depends on.
    Repo.transaction(fn ->
      # ownership: as above -- the target's live membership of the project's workspace.
      live =
        Repo.one(
          from m in Ravix.Workspaces.Membership,
            where:
              m.workspace_id == ^workspace_id and m.user_id == ^user_id and
                is_nil(m.revoked_at),
            lock: "FOR SHARE"
        )

      if is_nil(live), do: Repo.rollback(:not_workspace_member)

      %ProjectMember{}
      |> ProjectMember.changeset(%{
        project_id: project.id,
        user_id: user_id,
        invited_by: granted_by,
        role: role
      })
      |> Repo.insert!(on_conflict: [set: [role: role]], conflict_target: [:project_id, :user_id])
    end)
    |> case do
      {:ok, _row} ->
        Ravix.Hub.publish(project.id, :people)
        :ok

      {:error, :not_workspace_member} = refused ->
        refused
    end
  end

  @doc """
  Take a workspace member's direct grant away, and nothing else: they still
  reach the project through its workspace, at its default. Their seats,
  private tracks and queued work stay, unlike `remove_project_member/2`,
  which is for somebody leaving the project altogether. The hub is told.
  """
  @spec drop_project_grant(String.t(), String.t()) :: :ok
  def drop_project_grant(project_id, user_id) do
    Repo.delete_all(
      from m in ProjectMember, where: m.project_id == ^project_id and m.user_id == ^user_id
    )

    Ravix.Hub.publish(project_id, :people)
    :ok
  end

  defp seat_role(schema, key, id, user_id) do
    case Repo.one(
           from(m in schema,
             where: field(m, ^key) == ^id and m.user_id == ^user_id,
             select: %{role: m.role}
           )
         ) do
      nil -> nil
      %{role: role} -> role || :write
    end
  end

  # The project's members and their roles by login, in the one read the
  # people lists already made of them.
  defp project_seats(project_id) do
    rows =
      Repo.all(
        from(m in ProjectMember,
          join: u in assoc(m, :user),
          where: m.project_id == ^project_id,
          order_by: m.created_at,
          select: {u, m.role}
        )
      )

    {Enum.map(rows, &elem(&1, 0)), Map.new(rows, fn {u, role} -> {u.login, role || :write} end)}
  end

  # Every seat on these tracks, grouped by track id, and each seat's role
  # by login, in one read. A track nobody was named on is absent;
  # `people_by_track/3` supplies the default.
  defp seats_by_track(track_ids) do
    rows =
      Repo.all(
        from(m in TrackMember,
          join: u in assoc(m, :user),
          where: m.track_id in ^track_ids,
          order_by: m.created_at,
          select: {m.track_id, u, m.role}
        )
      )

    {Enum.group_by(rows, &elem(&1, 0), &elem(&1, 1)),
     rows
     |> Enum.group_by(&elem(&1, 0), fn {_, u, role} -> {u.login, role || :write} end)
     |> Map.new(fn {track_id, pairs} -> {track_id, Map.new(pairs)} end)}
  end

  defp seat_roles(schema, key, id) do
    Repo.all(
      from(m in schema,
        join: u in assoc(m, :user),
        where: field(m, ^key) == ^id,
        select: {u.login, m.role}
      )
    )
    |> Map.new(fn {login, role} -> {login, role || :write} end)
  end

  defp set_seat_role(schema, key, id, user_id, role) when role in [:read, :write, :admin] do
    {count, _} =
      Repo.update_all(
        from(m in schema, where: field(m, ^key) == ^id and m.user_id == ^user_id),
        set: [role: role]
      )

    count == 1
  end

  @doc "Everyone invited to a track, oldest invitation first. Excludes the owner."
  @spec members_of(String.t()) :: [User.t()]
  def members_of(track_id), do: seats_on(TrackMember, :track_id, track_id)

  @doc """
  The open tracks this person reaches one at a time -- a seat, a private
  track they made or, with `RAVIX_WORKSPACE_ACCESS` on, one shared with
  them -- across every project. `Ravix.Accounts.Access.visible/2` decides;
  this keeps only the tracks a project or workspace grant would not
  already have admitted.
  """
  @spec member_tracks(String.t()) :: [Track.t()]
  def member_tracks(user_id) do
    # ownership: no door before this membership query; `Access.visible/2`
    # is the visibility rule itself, applied here rather than copied.
    Repo.all(narrow_tracks(user_id) |> order_by([track: t], t.created_at))
  end

  @doc """
  Whether `user_id` reaches any open track of `project_id` one at a time.

  The third of the three ways into a project (see
  `Ravix.Accounts.Access.access_of/3`), asked as one `EXISTS` rather than
  by listing the person's tracks across every project and looking for this
  one in the answer. A closed track does not count, for the reason it does
  not count in `member_tracks/1`: there is no surface left on it to share.
  """
  @spec track_member_of?(String.t(), String.t()) :: boolean()
  def track_member_of?(project_id, user_id) do
    # ownership: no door before this query, used by Access.access_of to establish membership.
    Repo.exists?(narrow_tracks(user_id) |> where([track: t], t.project_id == ^project_id))
  end

  defp narrow_tracks(user_id) do
    from(t in Track,
      as: :track,
      join: p in Project,
      as: :project,
      on: p.id == t.project_id,
      where: is_nil(t.closed_at),
      select: t
    )
    |> Ravix.Accounts.Access.visible(user_id)
    |> where([track: t, vis_tm: tm], t.visibility == :private or not is_nil(tm.user_id))
  end

  # ── invitations to somebody who is not here yet ────────────────

  @doc """
  Invite a GitHub account that has not signed in here to a track. Inviting
  the same account again refreshes the login and avatar it is shown with.
  """
  @spec add_invite(%{
          track_id: String.t(),
          github_id: String.t(),
          login: String.t(),
          avatar_url: String.t() | nil,
          invited_by: String.t()
        }) :: :ok
  def add_invite(attrs) do
    %TrackInvite{}
    |> TrackInvite.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, [:login, :avatar_url]},
      conflict_target: [:track_id, :github_id]
    )

    :ok
  end

  @doc "The invitations waiting on a track, oldest first."
  @spec invites_of(String.t()) :: [invite()]
  def invites_of(track_id), do: invites_on(TrackInvite, :track_id, track_id)

  @doc "`invites_of/1` for several tracks at once, grouped by track id. Absent when a track has none."
  @spec invites_by_track([String.t()]) :: %{String.t() => [invite()]}
  def invites_by_track(track_ids) do
    Repo.all(
      from(i in TrackInvite,
        where: i.track_id in ^track_ids,
        order_by: i.created_at,
        select:
          {i.track_id, %Invite{github_id: i.github_id, login: i.login, avatar_url: i.avatar_url}}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "Withdraw a track invitation by the login it was sent to. True when one was there to withdraw."
  @spec remove_invite_by_login(String.t(), String.t()) :: boolean()
  def remove_invite_by_login(track_id, login),
    do: withdraw_invite(TrackInvite, :track_id, track_id, login)

  @doc """
  Turn every invitation waiting for this person into a membership.

  Run once, on the sign-in that creates or refreshes their account.
  Matching is on the GitHub id the profile just came back with, so an
  invitation sent to a login they have since changed still finds them, and
  one sent to a login somebody *else* now holds does not.

  Returns what they just joined, so the sign-in can say so.

  Projects are claimed **first**, and a track invitation on a project they
  have just joined outright is then dropped rather than honoured. It grants
  nothing they do not already have, and writing it would be writing the
  narrower row that `add_project_member/3` exists to delete.
  """
  @spec claim_invites(String.t(), String.t()) :: %{tracks: [Track.t()], projects: [Project.t()]}
  def claim_invites(user_id, github_id) do
    {:ok, joined} =
      Repo.transaction(fn ->
        projects = claim_project_invites(user_id, github_id)

        tracks =
          claim_track_invites(user_id, github_id) ++ claim_resource_invites(user_id, github_id)

        %{tracks: tracks, projects: projects}
      end)

    joined
  end

  defp claim_resource_invites(user_id, github_id) do
    invitations =
      Repo.all(
        from i in "resource_invites",
          where: i.github_id == ^github_id,
          select: %{resource_id: i.resource_id, invited_by: i.invited_by}
      )

    tracks =
      Enum.flat_map(invitations, fn invitation ->
        # ownership: no door -- the persisted invitation is the sign-in authorization;
        # the resource resolves its canonical project solely to check retirement.
        with %Ravix.Projects.Resource{} = resource <-
               Repo.get(Ravix.Projects.Resource, invitation.resource_id),
             %Project{} = project <- Projects.live_project(resource.project_id),
             false <- workspace_shared?(project) do
          seat_resource(user_id, resource.id, invitation.invited_by)
        else
          _ -> []
        end
      end)

    Repo.delete_all(from i in "resource_invites", where: i.github_id == ^github_id)
    tracks
  end

  @doc "An original project's preserved invitation link and its canonical project."
  def resource_for_link(hash) do
    # ownership: no door -- the matched invitation hash authorizes these labels.
    row =
      Repo.one(
        from l in "resource_links",
          join: r in Ravix.Projects.Resource,
          on: r.id == l.resource_id,
          join: p in Project,
          on: p.id == r.project_id,
          join: u in User,
          on: u.id == l.created_by,
          where:
            l.token_hash == ^hash and l.expires_at > fragment("now()") and
              is_nil(p.archived_at) and is_nil(p.deletion_requested_at),
          select: {p, r.id, u.login}
      )

    row
  end

  @doc "Seats granted by an original project's link/invite never include sibling resources."
  def seat_resource(user_id, resource_id, invited_by) do
    # ownership: no door -- People matched a persisted resource invitation or link.
    tracks =
      Repo.all(
        from t in Track,
          where:
            t.resource_id == ^resource_id and
              t.visibility == :project and is_nil(t.closed_at)
      )

    Enum.each(tracks, &add_member(&1.id, user_id, invited_by))
    tracks
  end

  @doc "Seats on the original canonical machine, for pre-consolidation invitations."
  def seat_default_resource(user_id, project_id, invited_by) do
    # ownership: no door -- People matched an original canonical invitation or link.
    tracks =
      Repo.all(
        from t in Track,
          where:
            t.project_id == ^project_id and
              is_nil(t.resource_id) and t.visibility == :project and is_nil(t.closed_at)
      )

    Enum.each(tracks, &add_member(&1.id, user_id, invited_by))
    tracks
  end

  def scoped_project_link?(hash) do
    Repo.exists?(from l in ProjectLink, where: l.token_hash == ^hash and l.resource_scoped)
  end

  defp claim_project_invites(user_id, github_id) do
    pending =
      Repo.all(from(i in ProjectInvite, where: i.github_id == ^github_id))

    projects =
      for invitation <- pending,
          # ownership: no door yet -- this runs during sign-in for a person
          # whose invitation rows are the only claim they have. The project
          # is read to check it is still there, not to decide who may see it.
          %Project{} = project <- [Projects.live_project(invitation.project_id)],
          # An archived project is not somewhere to arrive, and neither is
          # your own: ownership is the stronger claim and is a column, not a
          # row here.
          project.user_id != user_id,
          # Retired with the links on a workspace project (RAV-32), as a
          # track invitation is below: dropped, never honoured.
          not workspace_shared?(project) do
        if invitation.resource_scoped,
          do: seat_default_resource(user_id, project.id, "invite"),
          else: add_project_member(project.id, user_id, "invite")

        project
      end

    Repo.delete_all(from(i in ProjectInvite, where: i.github_id == ^github_id))
    projects
  end

  defp claim_track_invites(user_id, github_id) do
    pending =
      Repo.all(from(i in TrackInvite, where: i.github_id == ^github_id, select: i.track_id))

    tracks =
      for track_id <- pending,
          # A track closed while the invitation sat unclaimed is not
          # somewhere to arrive. Drop the invitation rather than granting a
          # dead seat.
          # ownership: no door yet -- this is sign-in, and the invitation row
          # naming this track is the only claim the person has.
          %Track{closed_at: nil} = track <- [Tracks.get_track(track_id)],
          # A workspace project's invitations are retired with its links
          # (ADR 0009 phase 5): dropped below, never honoured.
          # ownership: sign-in, as above; the project is read for its workspace.
          not workspace_shared?(track.project_id),
          track.visibility == :private or not project_member?(track.project_id, user_id) do
        add_member(track.id, user_id, "invite")
        track
      end

    Repo.delete_all(from(i in TrackInvite, where: i.github_id == ^github_id))
    tracks
  end

  # `Ravix.People.workspace_sharing?/1` for a project or its id, read here
  # because sign-in has no door to go through first.
  defp workspace_shared?(%Project{workspace_id: id}),
    do: is_binary(id) and Ravix.Config.workspace_access?()

  defp workspace_shared?(project_id) do
    # ownership: no door -- sign-in, as `claim_track_invites/2` says; the
    # project is read for its workspace alone.
    Ravix.Config.workspace_access?() and
      match?(%Project{workspace_id: id} when is_binary(id), Projects.live_project(project_id))
  end

  # ── the link ───────────────────────────────────────────────────

  @doc "Put a track's one link, replacing whatever was there. `ttl_ms` from now."
  @spec put_link(String.t(), String.t(), String.t(), integer()) :: :ok
  def put_link(track_id, token_hash, created_by, ttl_ms),
    do: put_link_row(TrackLink, :track_id, track_id, token_hash, created_by, ttl_ms)

  @doc "When a track's link was made and when it lapses, or nil. Never the hash."
  @spec link_of(String.t()) :: %{created_at: DateTime.t(), expires_at: DateTime.t()} | nil
  def link_of(track_id), do: link_row(TrackLink, :track_id, track_id)

  @doc "Delete a track's link. Nobody who came in on it is touched."
  @spec drop_link(String.t()) :: :ok
  def drop_link(track_id), do: drop_link_row(TrackLink, :track_id, track_id)

  @doc "The track a link opens, or nil if it is unknown, revoked, expired, or the track closed."
  @spec track_for_link(String.t()) :: Track.t() | nil
  def track_for_link(token_hash) do
    with %TrackLink{} = link <- Repo.get_by(TrackLink, token_hash: token_hash),
         true <- live?(link.expires_at),
         # ownership: no door but the link: holding it is the authorization,
         # and the row it matched names this track.
         %Track{closed_at: nil} = track <- Tracks.get_track(link.track_id) do
      track
    else
      _ -> nil
    end
  end

  # ── retiring the links for workspace sharing (ADR 0009 phase 5) ──────

  @doc """
  Every track on a workspace project still holding a legacy seat, a waiting
  invitation or a link, with its project, oldest first: what
  `Ravix.People.Cutover` has left to do. Empty once it has run.
  """
  @spec cutover_tracks() :: [{Track.t(), Project.t()}]
  def cutover_tracks do
    ids =
      [TrackMember, TrackInvite, TrackLink]
      |> Enum.flat_map(&Repo.all(from(r in &1, distinct: true, select: r.track_id)))
      |> Enum.uniq()

    # ownership: no door -- an operator step run as nobody, over every
    # workspace project; the project is read for its workspace and owner.
    Repo.all(
      from(t in Track,
        join: p in Project,
        on: p.id == t.project_id,
        where: t.id in ^ids and not is_nil(p.workspace_id),
        order_by: [asc: t.created_at, asc: t.id],
        select: {t, p}
      )
    )
  end

  @typedoc "Who else a legacy project is shared with, for an operator report. No tokens."
  @type inventory :: %{
          members: [String.t()],
          seats: [String.t()],
          invites: [String.t()],
          links: non_neg_integer()
        }

  @doc """
  For each of `projects`, who besides its owner holds anything on it: project
  members and track seats (by login, a seat's holder once however many
  tracks), waiting project and track invitations (by login), and how many
  project and track links have not expired. Only counts and logins: a link's
  hash is never read.
  """
  @spec inventory([Project.t()]) :: %{String.t() => inventory()}
  def inventory([]), do: %{}

  def inventory(projects) do
    ids = Enum.map(projects, & &1.id)
    owners = Map.new(projects, &{&1.id, &1.user_id})
    now = DateTime.utc_now()
    others = fn {project_id, user_id, _login} -> owners[project_id] != user_id end

    members =
      Repo.all(
        from(m in ProjectMember,
          join: u in assoc(m, :user),
          where: m.project_id in ^ids,
          select: {m.project_id, u.id, u.login}
        )
      )

    seats =
      Repo.all(
        from(m in TrackMember,
          join: t in assoc(m, :track),
          join: u in assoc(m, :user),
          where: t.project_id in ^ids,
          select: {t.project_id, u.id, u.login}
        )
      )

    # ownership: no door -- the operator report
    # `Ravix.Workspaces.PersonalAssignment`; the track only names its project.
    invites =
      Repo.all(
        from(i in ProjectInvite, where: i.project_id in ^ids, select: {i.project_id, i.login})
      ) ++
        Repo.all(
          from(i in TrackInvite,
            join: t in Track,
            on: t.id == i.track_id,
            where: t.project_id in ^ids,
            select: {t.project_id, i.login}
          )
        )

    project_links =
      Repo.all(
        from(l in ProjectLink,
          where: l.project_id in ^ids and l.expires_at > ^now,
          select: l.project_id
        )
      )

    # ownership: no door -- the operator report
    # `Ravix.Workspaces.PersonalAssignment`; the track only names its project.
    track_links =
      Repo.all(
        from(l in TrackLink,
          join: t in Track,
          on: t.id == l.track_id,
          where: t.project_id in ^ids and l.expires_at > ^now,
          select: t.project_id
        )
      )

    links = project_links ++ track_links

    logins = fn rows, project_id ->
      for {^project_id, _user_id, login} = row <- rows, others.(row), uniq: true, do: login
    end

    Map.new(ids, fn id ->
      {id,
       %{
         members: logins.(members, id),
         seats: logins.(seats, id),
         invites: for({^id, login} <- invites, uniq: true, do: login),
         links: Enum.count(links, &(&1 == id))
       }}
    end)
  end

  @doc "Withdraw every invitation waiting on a track. How many there were."
  @spec drop_invites(String.t()) :: non_neg_integer()
  def drop_invites(track_id) do
    {n, _} = Repo.delete_all(from(i in TrackInvite, where: i.track_id == ^track_id))
    n
  end

  @doc """
  Leave `attrs.user_id` an Inbox note about who lost access to a track.
  One per track and recipient: a second is not written, which is what makes
  the cutover safe to run again.
  """
  @spec put_notice(map()) :: :ok
  def put_notice(attrs) do
    %AccessNotice{}
    |> AccessNotice.changeset(attrs)
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:track_id, :user_id])

    :ok
  end

  @doc "A person's undismissed access notices, newest first, each with its track."
  @spec notices_for(String.t()) :: [{AccessNotice.t(), Track.t()}]
  def notices_for(user_id) do
    Repo.all(
      from(n in AccessNotice,
        join: t in assoc(n, :track),
        where: n.user_id == ^user_id and is_nil(n.dismissed_at),
        order_by: [desc: n.created_at, desc: n.id],
        select: {n, t}
      )
    )
  end

  @doc "Dismiss a notice, only its recipient's. True when there was one."
  @spec dismiss_notice(String.t(), String.t()) :: boolean()
  def dismiss_notice(id, user_id) do
    {n, _} =
      Repo.update_all(
        from(n in AccessNotice,
          where: n.id == ^id and n.user_id == ^user_id and is_nil(n.dismissed_at)
        ),
        set: [dismissed_at: DateTime.utc_now()]
      )

    n > 0
  end

  # ── who else is in a project ───────────────────────────────────

  @doc """
  Add project membership and replace redundant seats on project-visible tracks.
  Promotion preserves private invitations. Project removal revokes all seats.
  """
  @spec add_project_member(String.t(), String.t(), String.t()) :: :ok
  def add_project_member(project_id, user_id, invited_by) do
    %ProjectMember{}
    |> ProjectMember.changeset(%{
      project_id: project_id,
      user_id: user_id,
      invited_by: invited_by
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:project_id, :user_id])

    Repo.delete_all(
      from(m in TrackMember,
        where: m.user_id == ^user_id and m.track_id in subquery(track_ids_of(project_id))
      )
    )

    :ok
  end

  @doc """
  Remove every form of access and pending work for this person in the project.

  As with `remove_member/2`, the hub is told from here: this is where the
  access goes, so this is what announces it --- and only once the transaction
  has committed. A page told to re-read while the removal is still open reads
  the access it is about to lose and draws it back.

  One statement per kind of row, not one per track: a project with fifty
  tracks was fifty round trips of revoke, fifty of the agent grant and fifty
  of the queue, inside the transaction holding all fifty track rows locked.
  """
  @spec remove_project_member(String.t(), String.t()) :: :ok
  def remove_project_member(project_id, user_id) do
    # ownership: Access.project_access and the removal guard admitted the owner or departing member.
    # Lock the same track rows as queue submission and orphan cleanup.
    {:ok, cancelled} =
      Repo.transaction(fn ->
        tracks =
          Repo.all(
            from t in Track,
              where: t.project_id == ^project_id,
              order_by: t.id,
              lock: "FOR UPDATE"
          )

        ids = Enum.map(tracks, & &1.id)
        # ownership: Access.project_access admitted removal of this project participant.
        user = Repo.get!(User, user_id)

        Repo.delete_all(
          from m in ProjectMember, where: m.project_id == ^project_id and m.user_id == ^user_id
        )

        Repo.delete_all(
          from m in TrackMember, where: m.track_id in ^ids and m.user_id == ^user_id
        )

        Repo.delete_all(
          from i in TrackInvite,
            where:
              i.track_id in ^ids and (i.invited_by == ^user_id or i.github_id == ^user.github_id)
        )

        Repo.delete_all(
          from l in TrackLink, where: l.track_id in ^ids and l.created_by == ^user_id
        )

        # ownership: Access.project_access admitted revocation of this creator in the project.
        Repo.update_all(
          from(t in Track, where: t.project_id == ^project_id and t.created_by == ^user_id),
          set: [creator_revoked_at: DateTime.utc_now()]
        )

        # ownership: Access.project_access and the removal guard revoke sessions and queued work.
        Ravix.Previews.Store.revoke_tracks(ids, user_id)
        Ravix.Previews.Store.revoke_agent_tracks(ids, user_id)
        Ravix.PromptQueue.Store.cancel_user_tracks(ids, user_id)
      end)

    Ravix.PromptQueue.Store.publish_queues(cancelled)
    Ravix.Hub.publish(project_id, :people)
    :ok
  end

  @doc "Whether `user_id` was let into the whole project. The owner is not: ownership is a column."
  @spec project_member?(String.t(), String.t()) :: boolean()
  def project_member?(project_id, user_id),
    do: seated?(ProjectMember, :project_id, project_id, user_id)

  @doc "Everyone invited to the whole project, oldest first. Excludes the owner."
  @spec project_members_of(String.t()) :: [User.t()]
  def project_members_of(project_id), do: seats_on(ProjectMember, :project_id, project_id)

  @doc "The live projects this person was invited into whole. Never the ones they own."
  @spec member_projects(String.t()) :: [Project.t()]
  def member_projects(user_id) do
    Repo.all(
      from(m in ProjectMember,
        join: p in assoc(m, :project),
        where: m.user_id == ^user_id and is_nil(p.archived_at),
        order_by: p.created_at,
        select: p
      )
    )
  end

  @doc """
  The same promotion, for somebody who has not arrived yet.

  A pending invitation to a project-visible track is dropped with it, for the
  reason the memberships are: it would grant nothing on the sign-in that
  honoured them both, and until then it sits in the track's people list as
  a row whose remove control cancels an invitation that was already
  superseded. Private track invitations remain independent and are preserved.
  """
  @spec add_project_invite(%{
          project_id: String.t(),
          github_id: String.t(),
          login: String.t(),
          avatar_url: String.t() | nil,
          invited_by: String.t()
        }) :: :ok
  def add_project_invite(%{project_id: project_id, github_id: github_id} = attrs) do
    %ProjectInvite{}
    |> ProjectInvite.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, [:login, :avatar_url, :resource_scoped]},
      conflict_target: [:project_id, :github_id]
    )

    Repo.delete_all(
      from(i in TrackInvite,
        where: i.github_id == ^github_id and i.track_id in subquery(track_ids_of(project_id))
      )
    )

    :ok
  end

  @doc "Whether an invitation to the whole project is already out for this GitHub account."
  @spec has_project_invite?(String.t(), String.t()) :: boolean()
  def has_project_invite?(project_id, github_id) do
    Repo.exists?(
      from(i in ProjectInvite, where: i.project_id == ^project_id and i.github_id == ^github_id)
    )
  end

  @doc "The invitations waiting on a project, oldest first."
  @spec project_invites_of(String.t()) :: [invite()]
  def project_invites_of(project_id) do
    resources =
      from r in Ravix.Projects.Resource, where: r.project_id == ^project_id, select: r.id

    preserved =
      Repo.all(
        from i in "resource_invites",
          where: i.resource_id in subquery(resources),
          select: %Invite{github_id: i.github_id, login: i.login, avatar_url: i.avatar_url}
      )

    invites_on(ProjectInvite, :project_id, project_id) ++ preserved
  end

  @doc "Withdraw a project invitation by the login it was sent to. True when one was there to withdraw."
  @spec remove_project_invite_by_login(String.t(), String.t()) :: boolean()
  def remove_project_invite_by_login(project_id, login) do
    removed = withdraw_invite(ProjectInvite, :project_id, project_id, login)

    resources =
      from r in Ravix.Projects.Resource, where: r.project_id == ^project_id, select: r.id

    lowered = String.downcase(login)

    {count, _} =
      Repo.delete_all(
        from i in "resource_invites",
          where:
            i.resource_id in subquery(resources) and
              fragment("lower(?)", i.login) == ^lowered
      )

    removed or count > 0
  end

  @doc "Put a project's one link, replacing whatever was there. `ttl_ms` from now."
  @spec put_project_link(String.t(), String.t(), String.t(), integer()) :: :ok
  def put_project_link(project_id, token_hash, created_by, ttl_ms) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        drop_project_link(project_id)
        put_link_row(ProjectLink, :project_id, project_id, token_hash, created_by, ttl_ms)
      end)

    :ok
  end

  @doc "When a project's link was made and when it lapses, or nil. Never the hash."
  @spec project_link_of(String.t()) :: %{created_at: DateTime.t(), expires_at: DateTime.t()} | nil
  def project_link_of(project_id) do
    link_row(ProjectLink, :project_id, project_id) || preserved_link_of(project_id)
  end

  defp preserved_link_of(project_id) do
    # ownership: Access.project_access admitted the canonical project's link settings.
    Repo.one(
      from l in "resource_links",
        join: r in Ravix.Projects.Resource,
        on: r.id == l.resource_id,
        where: r.project_id == ^project_id,
        order_by: [desc: l.created_at],
        limit: 1,
        select: %{
          created_at: type(l.created_at, :utc_datetime_usec),
          expires_at: type(l.expires_at, :utc_datetime_usec)
        }
    )
  end

  @doc "Delete a project's link. Nobody who came in on it is touched."
  @spec drop_project_link(String.t()) :: :ok
  def drop_project_link(project_id) do
    drop_link_row(ProjectLink, :project_id, project_id)

    resources =
      from r in Ravix.Projects.Resource, where: r.project_id == ^project_id, select: r.id

    Repo.delete_all(from l in "resource_links", where: l.resource_id in subquery(resources))
    :ok
  end

  @doc "The project a link opens, or nil if it is unknown, revoked, expired or archived."
  @spec project_for_link(String.t()) :: Project.t() | nil
  def project_for_link(token_hash) do
    with %ProjectLink{} = link <- Repo.get_by(ProjectLink, token_hash: token_hash),
         true <- live?(link.expires_at),
         # ownership: no door but the link: holding it is the authorization,
         # and the row it matched names this project.
         %Project{} = project <- Projects.live_project(link.project_id) do
      project
    else
      _ -> nil
    end
  end

  # ── the same row, on either side of the line ─────────────────────────
  #
  # A track and a project are shared by the same three tables one level
  # apart, and seven of these reads were the same query written twice. They
  # are one query each now, with the schema and its key passed in.
  #
  # What is *not* here is as deliberate: `add_member/3`, `remove_member/2`,
  # `add_invite/1` and `track_for_link/1` still have their project twins
  # written out, because those four genuinely differ -- the wider grant
  # deletes the narrower rows, removing somebody from a project revokes
  # previews on every track under it, and a link is dead when its track
  # closes or its project is archived, which are different questions. Before
  # this, all eleven pairs looked alike and a reader had no way to tell the
  # seven that were the same from the four that were not.
  #
  # The public names stay one per unit of sharing. Passing the unit as an
  # argument would make `member?(wrong_scope, id, user)` a thing that
  # compiles, in the module where that answer decides who gets a shell.

  defp seated?(schema, key, id, user_id) do
    Repo.exists?(from(m in schema, where: field(m, ^key) == ^id and m.user_id == ^user_id))
  end

  defp seats_on(schema, key, id) do
    Repo.all(
      from(m in schema,
        join: u in assoc(m, :user),
        where: field(m, ^key) == ^id,
        order_by: m.created_at,
        select: u
      )
    )
  end

  defp invites_on(schema, key, id) do
    Repo.all(
      from(i in schema,
        where: field(i, ^key) == ^id,
        order_by: i.created_at,
        select: %Invite{github_id: i.github_id, login: i.login, avatar_url: i.avatar_url}
      )
    )
  end

  # True when there was one to withdraw, which is how the routes tell an
  # invitation that was cancelled from a name nobody had invited.
  defp withdraw_invite(schema, key, id, login) do
    lowered = String.downcase(login)

    {n, _} =
      Repo.delete_all(
        from(i in schema,
          where: field(i, ^key) == ^id and fragment("LOWER(?)", i.login) == ^lowered
        )
      )

    n > 0
  end

  # One row per subject, by primary key, which is what makes minting a new
  # link *the* revoke rather than a second thing to remember.
  defp put_link_row(schema, key, id, token_hash, created_by, ttl_ms) do
    now = DateTime.utc_now()
    fields = [:token_hash, :created_by, :created_at, :expires_at]
    fields = if schema == ProjectLink, do: [:resource_scoped | fields], else: fields

    schema
    |> struct()
    |> schema.changeset(%{
      key => id,
      :token_hash => token_hash,
      :created_by => created_by,
      :created_at => now,
      :expires_at => DateTime.add(now, ttl_ms, :millisecond)
    })
    |> Repo.insert!(
      on_conflict: {:replace, fields},
      conflict_target: key
    )

    :ok
  end

  defp link_row(schema, key, id) do
    Repo.one(
      from(l in schema,
        where: field(l, ^key) == ^id,
        select: %{created_at: l.created_at, expires_at: l.expires_at}
      )
    )
  end

  defp drop_link_row(schema, key, id) do
    Repo.delete_all(from(l in schema, where: field(l, ^key) == ^id))
    :ok
  end

  defp live?(expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp track_ids_of(project_id),
    do:
      from(t in Track,
        where: t.project_id == ^project_id and t.visibility == :project,
        select: t.id
      )

  # ── what you have not read ─────────────────────────────────────

  @doc "Record that `user_id` looked at a track, at `at` (now by default)."
  @spec mark_read(String.t(), String.t(), DateTime.t()) :: :ok
  def mark_read(track_id, user_id, at \\ DateTime.utc_now()) do
    %TrackRead{}
    |> TrackRead.changeset(%{track_id: track_id, user_id: user_id, seen_at: at})
    |> Repo.insert!(on_conflict: {:replace, [:seen_at]}, conflict_target: [:track_id, :user_id])

    :ok
  end

  @doc "When this person last looked at each of a project's tracks, by track id."
  @spec reads_of(String.t(), String.t()) :: %{String.t() => DateTime.t()}
  def reads_of(user_id, project_id) do
    Repo.all(
      from(r in TrackRead,
        join: t in assoc(r, :track),
        where: r.user_id == ^user_id and t.project_id == ^project_id,
        select: {r.track_id, r.seen_at}
      )
    )
    |> Map.new()
  end

  @doc "When this person last looked at a track, or nil if never."
  @spec last_read_of(String.t(), String.t()) :: DateTime.t() | nil
  def last_read_of(track_id, user_id) do
    Repo.one(
      from(r in TrackRead,
        where: r.track_id == ^track_id and r.user_id == ^user_id,
        select: r.seen_at
      )
    )
  end

  # ── the link, as the page that follows one reads it ──────────────────

  @doc """
  Whoever minted the link now under `hash`, by login. Nil if nobody did.

  The row is re-read by hash as well as by id: a link that was replaced
  between a caller's lookup and this one belongs to whoever minted the
  *current* link, and naming the previous sender would be a small lie on a
  page whose whole job is saying who is asking.
  """
  @spec minted_by(module(), atom(), String.t(), String.t()) :: String.t() | nil
  def minted_by(schema, key, id, hash) do
    # ownership: no door -- a link is read before anybody is signed in, and
    # the hash is the authorization, matched against this row right here. The
    # user read turns the stored `created_by` into the login a page shows, and
    # nothing else is decided by it.
    with %{created_by: user_id} <- Repo.get_by(schema, [{key, id}, {:token_hash, hash}]),
         %User{login: login} <- Ravix.Accounts.Store.get_user(user_id) do
      login
    else
      _ -> nil
    end
  end

  @doc """
  The project a link's track sits on, if it is still there.

  Deliberately the same read `Ravix.Accounts.Access` makes, rather than a
  second opinion about what "archived" means. A link to a track on an
  archived project opens nothing.
  """
  # ownership: no door but the link -- another context's rows, reached because
  # a link that has already matched a track row names the project it is on.
  @spec live_project(String.t()) :: Ravix.Projects.Project.t() | nil
  defdelegate live_project(project_id), to: Projects

  # ── the people lists ─────────────────────────────────────────────────
  #
  # Assembly rather than access: ids in, a list of people out. They said
  # "Unscoped:" three times over while they lived in `Ravix.People`, which is
  # the sentence this module exists so that nobody has to write.

  @doc """
  Everyone on a track, owner first.

  The owner is not a row in `track_members`: they own the project, which is
  a stronger claim that survives every membership being deleted, so they
  are prepended here rather than written into the table. A synthetic row
  would have to be kept in step with the project's `user_id` forever, and
  the day it was not, the owner would lose their own track.

  Project members are in this list too, because the question it answers is
  "who can see this" and they can. They carry `via: :project` so the dialog
  can say *why* (a name you do not remember inviting to this branch is
  alarming until the row tells you it came in one level up) and so the
  remove control beside them can be the one that actually works.

  Somebody who is both is shown once, as a project member: that is the row
  that is granting the access, and it is the one whose removal would not be
  enough on its own.

  """
  @spec people_of(String.t(), String.t(), String.t()) :: [person()]
  def people_of(track_id, owner_id, project_id) do
    {wide, project_roles} = project_seats(project_id)
    # ownership: the caller passed `Access.track_access/2` for this track.
    audience = Ravix.Accounts.Access.workspace_audience(project_id, [track_id])
    {shared, seen} = shared_people(owner_id, wide, audience.members)

    people = assemble(shared, seen, members_of(track_id), invites_of(track_id))

    track_id
    |> private_people(people, Map.get(audience.permitted, track_id, []))
    |> with_roles(member_roles(track_id), project_roles)
  end

  # ADR 0010: each person's role as the list shows it. A track seat and a
  # project membership carry their own; the owner and a private track's
  # creator are always admin; the workspace's people work as write.
  defp with_roles(people, track_roles, project_roles) do
    Enum.map(people, fn person ->
      role =
        case person.via do
          via when via in [:owner, :creator] -> :admin
          :project -> Map.get(project_roles, person.login, :write)
          :track -> Map.get(track_roles, person.login, :write)
          via when via in [:workspace, :shared] -> :write
          :pending -> nil
        end

      %{person | role: role}
    end)
  end

  @doc """
  `people_of/3` for a whole project's tracks at once, keyed by track id.

  The sidebar asks this of every track it lists, and asked one at a time it
  is four queries each: the same project members and the same owner, read
  again per row. Twenty tracks cost eighty-three queries and eighty of them
  had the answer already. Here the two project-wide lists are read once and
  the two per-track ones are read for every named track together, so the
  count stops depending on how many tracks a project has.

  Every id given is a key in the answer, including the tracks with nobody
  on them beyond the project's own people.

  """
  @spec people_by_track([String.t()], String.t(), String.t()) :: %{String.t() => [person()]}
  def people_by_track([], _owner_id, _project_id), do: %{}

  def people_by_track(track_ids, owner_id, project_id) do
    {wide, project_roles} = project_seats(project_id)
    # ownership: Access.track_access or Access.open_tracks admitted these track IDs.
    audience = Ravix.Accounts.Access.workspace_audience(project_id, track_ids)
    {shared, seen} = shared_people(owner_id, wide, audience.members)
    {members, roles} = seats_by_track(track_ids)
    invites = invites_by_track(track_ids)

    # ownership: Access.track_access or Access.open_tracks admitted these track IDs.
    tracks = Map.new(Tracks.get_tracks(track_ids), &{&1.id, &1})

    Map.new(track_ids, fn track_id ->
      {track_id,
       private_people(
         tracks[track_id],
         assemble(
           shared,
           seen,
           Map.get(members, track_id, []),
           Map.get(invites, track_id, [])
         ),
         Map.get(audience.permitted, track_id, [])
       )
       |> with_roles(Map.get(roles, track_id, %{}), project_roles)}
    end)
  end

  # ownership: callers passed Access.track_access or filtered their track list.
  # `permitted` is who holds a live permission row on it, as
  # `Access.workspace_audience/2` found them: none while the switch is off.
  defp private_people(track_id, people, permitted) do
    track = if is_binary(track_id), do: Tracks.get_track(track_id), else: track_id

    case track do
      %Track{id: id, visibility: :private, created_by: creator, creator_revoked_at: revoked} ->
        members = members_of(id)

        creator_people =
          if creator && is_nil(revoked),
            do: Enum.map(owner_entry(creator), &%{&1 | via: :creator}),
            else: []

        seen = MapSet.new(if creator_people == [], do: [], else: [creator])
        shared = Enum.reject(permitted, &MapSet.member?(seen, &1.id))

        assemble(
          creator_people ++ Enum.map(shared, &Person.new(&1, :shared)),
          MapSet.union(seen, MapSet.new(shared, & &1.id)),
          members,
          invites_of(id)
        )

      _ ->
        people
    end
  end

  # The half of the list that is the same for every track on a project, and
  # the ids already in it: the owner, project members, then any live
  # workspace members not already one of those.
  defp shared_people(owner_id, wide, workspace) do
    seen = MapSet.new([owner_id | Enum.map(wide, & &1.id)])
    extra = Enum.reject(workspace, &MapSet.member?(seen, &1.id))

    {owner_entry(owner_id) ++
       Enum.map(wide, &Person.new(&1, :project)) ++ Enum.map(extra, &Person.new(&1, :workspace)),
     MapSet.union(MapSet.new(wide, & &1.id), MapSet.new(extra, & &1.id))}
  end

  # Pending last, because they cannot read anything yet and the list is
  # mostly read to answer "who can see this".
  defp assemble(shared, seen, members, invites) do
    narrow = Enum.reject(members, &MapSet.member?(seen, &1.id))

    shared ++
      Enum.map(narrow, &Person.new(&1, :track)) ++
      Enum.map(invites, &pending_person/1)
  end

  @doc "A `Ravix.People.Profile` for a user row: login, name, avatar, nothing else."
  @spec present_person(User.t()) :: profile()
  defdelegate present_person(user), to: Profile, as: :from_user

  defp pending_person(%Invite{login: login, avatar_url: avatar_url}),
    do: Person.pending(login, avatar_url)

  defp owner_entry(owner_id) do
    # ownership: turning the project's `user_id` column into a name for the
    # list, whose callers in `Ravix.People` went through `Access.track_access/2`
    # or `Access.project_access/2`. Ownership is that column, never a row here.
    case Ravix.Accounts.Store.get_user(owner_id) do
      %User{} = owner -> [Person.new(owner, :owner)]
      nil -> []
    end
  end
end
