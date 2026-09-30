defmodule Ravix.Workspaces.Store do
  @moduledoc """
  The workspace rows, with nobody's permission established.

  Ids in, rows out, as `Ravix.Projects.Store` is. `Ravix.Workspaces` holds
  the scoped readers, `Ravix.Accounts.Access.workspace_access/2` is the door,
  and `Ravix.Workspaces.Backfill` drives the batch functions at the bottom.
  Nothing here is reachable from a page.
  """

  import Ecto.Query

  require Logger

  alias Ravix.Accounts.User
  alias Ravix.Projects.Project
  alias Ravix.Repo

  alias Ravix.Workspaces.{
    CatalogRepo,
    ConnectState,
    Installation,
    Invite,
    Membership,
    RepositoryReservation,
    Workspace
  }

  # A project moving in brings the installation it clones through, when
  # `attach_backing_installations/2` allows it; at most this many for one
  # workspace at a time, which no workspace comes near.
  @attach_on_move 1_000

  @doc "A workspace that exists and has not been archived, or nil."
  @spec live_workspace(String.t() | nil) :: Workspace.t() | nil
  def live_workspace(id) when is_binary(id) do
    case Repo.get(Workspace, id) do
      %Workspace{archived_at: nil} = workspace -> workspace
      _ -> nil
    end
  end

  def live_workspace(_id), do: nil

  @doc "The unrevoked membership of `user_id` in `workspace_id`, or nil."
  @spec membership(String.t(), String.t()) :: Membership.t() | nil
  def membership(workspace_id, user_id) when is_binary(workspace_id) and is_binary(user_id) do
    Repo.one(
      from m in Membership,
        where: m.workspace_id == ^workspace_id and m.user_id == ^user_id and is_nil(m.revoked_at)
    )
  end

  def membership(_workspace_id, _user_id), do: nil

  @doc "A person's personal workspace, or nil until the backfill has reached them."
  @spec personal_workspace(String.t()) :: Workspace.t() | nil
  def personal_workspace(user_id) do
    Repo.one(
      from w in Workspace,
        where: w.personal_user_id == ^user_id and w.kind == :personal and is_nil(w.archived_at)
    )
  end

  @doc "Live workspaces a person holds an unrevoked membership in, oldest first."
  @spec workspaces_of(String.t()) :: [{Workspace.t(), Membership.role()}]
  def workspaces_of(user_id) do
    Repo.all(
      from w in Workspace,
        join: m in Membership,
        on: m.workspace_id == w.id,
        where: m.user_id == ^user_id and is_nil(m.revoked_at) and is_nil(w.archived_at),
        order_by: [asc: w.created_at, asc: w.id],
        select: {w, m.role}
    )
  end

  @doc """
  Give `user` their personal workspace and its owner membership, unless
  they already have them. Returns the personal workspace.

  The sign-up half of the backfill: `Ravix.Accounts.upsert_user/1` calls it
  in the sign-in's own transaction, so a person created by this release has
  a personal workspace from the moment their row exists. Same shape as
  `insert_personal_workspaces/1` and `insert_owner_memberships/1` (named
  after the login at creation, never renamed with it), and the same
  `ON CONFLICT DO NOTHING` on the same unique keys, so it and a backfill
  running on another instance cannot both mint one. A revoked or archived
  row is left exactly as it is. Not found only if the row is gone again
  before the read below, which nothing in this release does.
  """
  @spec ensure_personal_workspace(User.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def ensure_personal_workspace(%User{id: user_id, login: login}) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Workspace,
      [
        %{
          id: Ecto.UUID.generate(),
          name: login,
          kind: :personal,
          personal_user_id: user_id,
          created_by_user_id: user_id,
          created_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(personal_user_id) WHERE personal_user_id IS NOT NULL"}
    )

    # A conflict above waited for the other writer to commit, so this read,
    # a new statement, sees whichever row won.
    case Repo.one(from w in Workspace, where: w.personal_user_id == ^user_id) do
      %Workspace{} = workspace ->
        Repo.insert_all(
          Membership,
          [%{workspace_id: workspace.id, user_id: user_id, role: :owner, created_at: now}],
          on_conflict: :nothing
        )

        {:ok, workspace}

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Revoke `user_id`'s membership of `workspace_id` on behalf of `actor_id`.

  Stamps `revoked_at` rather than deleting, so the backfill cannot hand a
  removed owner their membership back, and deletes their permission rows in
  the workspace's tracks, so re-admitting them restores none of those
  shares. Every live membership of the workspace is locked first, and the remover's own standing is read under
  that lock: an admin demoted or removed at the same moment cannot finish a
  removal they started, and two owners removing each other at once cannot
  leave the workspace with none. Only an owner removes an owner.
  """
  @spec revoke_membership(String.t(), String.t(), String.t()) ::
          {:ok, Membership.t()}
          | {:error, :not_found | :actor_gone | :not_manager | :owner_only | :last_owner}
  def revoke_membership(workspace_id, user_id, actor_id) do
    # ownership: `Workspaces.remove_member/3` went through `Access.workspace_access/2`;
    # the permission rows deleted inside are this membership's (see below).
    Repo.transaction(fn ->
      live =
        Repo.all(
          from m in Membership,
            where: m.workspace_id == ^workspace_id and is_nil(m.revoked_at),
            order_by: m.user_id,
            lock: "FOR UPDATE"
        )

      with {:ok, actor} <- live_member(live, actor_id, :actor_gone),
           :ok <- manager(actor),
           {:ok, target} <- live_member(live, user_id, :not_found),
           :ok <- removable(target, actor, Enum.count(live, &(&1.role == :owner))) do
        revoked =
          target
          |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
          |> Repo.update!()

        # ownership: `Workspaces.remove_member/3` admitted the remover through
        # `Access.workspace_access/2`, re-checked under this lock. ADR 0009:
        # removal invalidates their explicit track grants in the workspace,
        # so a later re-admission starts from none. A share racing this waits
        # on the membership lock (`People.Store.add_permission/4`).
        Repo.delete_all(
          from p in Ravix.Tracks.TrackPermission,
            where: p.workspace_id == ^workspace_id and p.user_id == ^user_id
        )

        revoked
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp live_member(live, user_id, missing) do
    case Enum.find(live, &(&1.user_id == user_id)) do
      %Membership{} = membership -> {:ok, membership}
      nil -> {:error, missing}
    end
  end

  # ownership: `Access.can?/2` is a pure answer about a role, not a door;
  # asked here so the role table has one home.
  defp manager(%Membership{role: role}) do
    if Ravix.Accounts.Access.can?(role, :manage_members), do: :ok, else: {:error, :not_manager}
  end

  defp removable(%Membership{role: :owner}, %Membership{role: role}, _owners) when role != :owner,
    do: {:error, :owner_only}

  defp removable(%Membership{role: :owner}, _actor, owners) when owners <= 1,
    do: {:error, :last_owner}

  defp removable(_target, _actor, _owners), do: :ok

  @doc """
  Live projects in live workspaces where `user_id` holds a live membership,
  oldest first. Rows only: `Ravix.Projects.list/2` asks for them only with
  `RAVIX_WORKSPACE_ACCESS` on, and `Access.access_of/3` decides from there.
  """
  @spec member_projects(String.t()) :: [Project.t()]
  def member_projects(user_id) do
    # ownership: no door before this one -- a live membership is the fourth
    # way in (`Access.access_of/3`), and this read is that fact.
    Repo.all(
      from p in Project,
        join: w in Workspace,
        on: w.id == p.workspace_id and is_nil(w.archived_at),
        join: m in Membership,
        on: m.workspace_id == w.id and m.user_id == ^user_id and is_nil(m.revoked_at),
        where: is_nil(p.archived_at) and is_nil(p.deletion_requested_at),
        order_by: [asc: p.created_at, asc: p.id]
    )
  end

  @doc "The users holding a live membership of a workspace, by login."
  @spec live_members(String.t()) :: [User.t()]
  def live_members(workspace_id) do
    # ownership: `Access.workspace_audience/2` asks, for tracks its caller
    # was already admitted to; the user rows are who those members are.
    Repo.all(
      from u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        where: m.workspace_id == ^workspace_id and is_nil(m.revoked_at),
        order_by: [asc: u.login]
    )
  end

  @doc """
  Live members of a workspace whose login or name starts with `prefix`
  (case-insensitive), leaving out `except` ids, by login, at most `limit`.
  The Share dialog's @-mention list: nobody outside the workspace is in it.
  """
  @spec search_members(String.t(), String.t(), [String.t()], pos_integer()) :: [User.t()]
  def search_members(workspace_id, prefix, except, limit) do
    like = String.downcase(prefix) |> String.replace(~r/[\\%_]/, "\\\\\\0") |> Kernel.<>("%")

    # ownership: `Ravix.People.share_candidates/3` admitted the caller as the
    # track's manager through `Access.track_access/2` and `Access.workspace_grant/3`.
    Repo.all(
      from u in User,
        join: m in Membership,
        on: m.user_id == u.id,
        where: m.workspace_id == ^workspace_id and is_nil(m.revoked_at),
        where: u.id not in ^except,
        where:
          fragment("LOWER(?) LIKE ?", u.login, ^like) or
            fragment("LOWER(COALESCE(?, '')) LIKE ?", u.name, ^like),
        order_by: [asc: u.login],
        limit: ^limit
    )
  end

  @doc "Whether anybody besides `user_id` holds a live membership of the workspace."
  @spec others_in?(String.t(), String.t()) :: boolean()
  def others_in?(workspace_id, user_id) do
    Repo.exists?(
      from m in Membership,
        where: m.workspace_id == ^workspace_id and m.user_id != ^user_id and is_nil(m.revoked_at)
    )
  end

  @doc "The ids of the live projects in a workspace."
  @spec project_ids(String.t()) :: [String.t()]
  def project_ids(workspace_id) do
    # ownership: no door -- ids only, for telling each project's hub that a
    # workspace membership it may be read through has changed.
    Repo.all(
      from p in Project,
        where: p.workspace_id == ^workspace_id and is_nil(p.archived_at),
        select: p.id
    )
  end

  # ── team workspaces and their people (phase 4a) ──────────────────────

  @doc """
  Create a team workspace with `user_id` as its one owner, in one
  transaction: nobody ever sees a workspace without an owner.
  """
  @spec create_team_workspace(String.t(), String.t()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_team_workspace(user_id, name) do
    Repo.transaction(fn ->
      with {:ok, workspace} <-
             %Workspace{}
             |> Workspace.changeset(%{name: name, kind: :team, created_by_user_id: user_id})
             |> Repo.insert(),
           {:ok, _owner} <-
             %Membership{}
             |> Membership.changeset(%{
               workspace_id: workspace.id,
               user_id: user_id,
               role: :owner
             })
             |> Repo.insert() do
        workspace
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  A workspace's live members with their users, owners first, then admins,
  then members, each by login.
  """
  @spec members(String.t()) :: [%{user: User.t(), role: Membership.role()}]
  def members(workspace_id) do
    # ownership: no door -- the user rows of a workspace's own memberships;
    # `Ravix.Workspaces.people/2` reads this behind `Access.workspace_access/2`.
    Repo.all(
      from m in Membership,
        join: u in User,
        on: u.id == m.user_id,
        where: m.workspace_id == ^workspace_id and is_nil(m.revoked_at),
        order_by: [
          asc: fragment("CASE ? WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END", m.role),
          asc: fragment("lower(?)", u.login)
        ],
        select: %{user: u, role: m.role}
    )
  end

  @doc "A workspace's waiting invitations, by login."
  @spec invites(String.t()) :: [Invite.t()]
  def invites(workspace_id) do
    Repo.all(
      from i in Invite, where: i.workspace_id == ^workspace_id, order_by: [asc: i.login_key]
    )
  end

  @doc """
  Make `user_id` a member of `workspace_id` with `role`, on `invited_by`'s
  word. Somebody removed earlier is let back in with the new role; somebody
  already a live member is left exactly as they are, and answered
  `:already_member`.
  """
  @spec add_member(String.t(), String.t(), Membership.role(), String.t() | nil) ::
          :ok | {:error, :already_member}
  def add_member(workspace_id, user_id, role, invited_by) do
    case insert_membership(workspace_id, user_id, role, invited_by) do
      1 -> :ok
      0 -> {:error, :already_member}
    end
  end

  # One statement, so two invitations landing at once cannot write two rows
  # or reinstate over a live one: a live row matches the conflict and fails
  # the `WHERE`, and nothing is written.
  defp insert_membership(workspace_id, user_id, role, invited_by) do
    now = DateTime.utc_now()

    reinstate =
      from m in Membership,
        where: not is_nil(m.revoked_at),
        update: [
          set: [
            role: ^role,
            revoked_at: nil,
            invited_by_user_id: ^invited_by,
            created_at: ^now
          ]
        ]

    {count, _} =
      Repo.insert_all(
        Membership,
        [
          %{
            workspace_id: workspace_id,
            user_id: user_id,
            role: role,
            invited_by_user_id: invited_by,
            created_at: now
          }
        ],
        on_conflict: reinstate,
        conflict_target: [:workspace_id, :user_id]
      )

    count
  end

  @doc """
  Record an invitation for somebody not signed in here, on `actor_id`'s
  word, or update the one already waiting on the same login (its role, and
  its GitHub id when that has become known).

  The actor's membership is read again under a share lock, and the waiting
  invitation under an update lock, so a demotion or a second invitation at
  the same moment waits. An invitation an owner sent, or one for an owner or
  admin, is changed by an owner only (`Invite.protected?/1`).
  """
  @spec put_invite(map(), String.t()) ::
          {:ok, Invite.t()} | {:error, :actor_gone | :owner_only | Ecto.Changeset.t()}
  def put_invite(%{workspace_id: workspace_id, login: login} = attrs, actor_id) do
    Repo.transaction(fn ->
      with {:ok, actor} <- actor(workspace_id, actor_id),
           :ok <- may_touch(waiting_invite(workspace_id, login), actor) do
        attrs
        |> Map.merge(%{invited_by_user_id: actor_id, invited_by_role: actor.role})
        |> insert_invite()
      end
      |> case do
        {:ok, invite} -> invite
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_invite(attrs) do
    %Invite{}
    |> Invite.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [:login, :github_id, :avatar_url, :role, :invited_by_user_id, :invited_by_role]},
      conflict_target: [:workspace_id, :login_key],
      returning: true
    )
  end

  @doc """
  Withdraw the invitation waiting on `login` in `workspace_id`, on
  `actor_id`'s word, under the same locks and rule as `put_invite/2`.
  """
  @spec delete_invite(String.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :actor_gone | :owner_only}
  def delete_invite(workspace_id, login, actor_id) do
    Repo.transaction(fn ->
      with {:ok, actor} <- actor(workspace_id, actor_id),
           %Invite{} = invite <- waiting_invite(workspace_id, login) || {:error, :not_found},
           :ok <- may_touch(invite, actor) do
        Repo.delete!(invite)
      end
      |> case do
        %Invite{} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp actor(workspace_id, actor_id) do
    case Repo.one(
           from m in Membership,
             where:
               m.workspace_id == ^workspace_id and m.user_id == ^actor_id and
                 is_nil(m.revoked_at),
             lock: "FOR SHARE"
         ) do
      %Membership{} = membership -> {:ok, membership}
      nil -> {:error, :actor_gone}
    end
  end

  defp waiting_invite(workspace_id, login) do
    key = Invite.login_key(login)

    Repo.one(
      from i in Invite,
        where: i.workspace_id == ^workspace_id and i.login_key == ^key,
        lock: "FOR UPDATE"
    )
  end

  defp may_touch(nil, _actor), do: :ok
  defp may_touch(%Invite{}, %Membership{role: :owner}), do: :ok

  defp may_touch(%Invite{} = invite, _actor),
    do: if(Invite.protected?(invite), do: {:error, :owner_only}, else: :ok)

  @doc """
  Turn the invitations waiting on `user` into memberships, and return the
  workspaces they joined.

  Called by `Ravix.Accounts.upsert_user/1` inside the sign-in's own
  transaction, so the person and their memberships commit together. An
  invitation that carries a GitHub id matches that id and nothing else; one
  written without (no GitHub App to ask) matches the login,
  case-insensitively. Accepted invitations are deleted. A live membership
  already there keeps its role; an archived workspace's invitation is
  dropped without admitting anybody.
  """
  @spec accept_invites(User.t()) :: [String.t()]
  def accept_invites(%User{id: user_id, github_id: github_id, login: login}) do
    key = Invite.login_key(login || "")

    # Only the invitation rows are locked: a sign-in must not hold the
    # workspace rows, which every other writer of that workspace reads.
    waiting =
      Repo.all(
        from i in Invite,
          where: i.github_id == ^github_id or (is_nil(i.github_id) and i.login_key == ^key),
          order_by: [asc: i.id],
          lock: "FOR UPDATE"
      )

    workspace_ids = Enum.map(waiting, & &1.workspace_id)

    live =
      Repo.all(
        from w in Workspace,
          where: w.id in ^workspace_ids and is_nil(w.archived_at),
          select: w.id
      )
      |> MapSet.new()

    joined =
      for invite <- waiting,
          MapSet.member?(live, invite.workspace_id),
          insert_membership(invite.workspace_id, user_id, invite.role, invite.invited_by_user_id) ==
            1,
          do: invite.workspace_id

    Repo.delete_all(from i in Invite, where: i.id in ^Enum.map(waiting, & &1.id))
    joined
  end

  @doc """
  Change `user_id`'s role in `workspace_id` on behalf of `actor_id`.

  Under the same lock as `revoke_membership/3`, and for the same reasons:
  the actor is read again under it, and only a live owner changes roles.
  The last owner cannot be demoted.
  """
  @spec set_role(String.t(), String.t(), Membership.role(), String.t()) ::
          {:ok, Membership.t()}
          | {:error, :not_found | :actor_gone | :not_owner | :last_owner}
  def set_role(workspace_id, user_id, role, actor_id) do
    Repo.transaction(fn ->
      live =
        Repo.all(
          from m in Membership,
            where: m.workspace_id == ^workspace_id and is_nil(m.revoked_at),
            order_by: m.user_id,
            lock: "FOR UPDATE"
        )

      owners = Enum.count(live, &(&1.role == :owner))

      with {:ok, actor} <- live_member(live, actor_id, :actor_gone),
           :ok <- owner(actor),
           {:ok, target} <- live_member(live, user_id, :not_found),
           :ok <- demotable(target, role, owners) do
        target |> Ecto.Changeset.change(role: role) |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Rename a live workspace; not found once it is archived or gone."
  @spec rename_workspace(String.t(), String.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def rename_workspace(workspace_id, name) do
    case live_workspace(workspace_id) do
      nil -> {:error, :not_found}
      workspace -> {:ok, workspace |> Ecto.Changeset.change(name: name) |> Repo.update!()}
    end
  end

  defp owner(%Membership{role: :owner}), do: :ok
  defp owner(%Membership{}), do: {:error, :not_owner}

  defp demotable(%Membership{role: :owner}, role, owners) when role != :owner and owners <= 1,
    do: {:error, :last_owner}

  defp demotable(_target, _role, _owners), do: :ok

  @typedoc """
  Whose creation path a reservation holds back: a workspace's, or, for a
  duplicate still in the legacy layout, its owner's. A reservation row has
  exactly one of the two, so the write and the lookup cannot disagree.
  """
  @type scope :: {:workspace, String.t()} | {:legacy, String.t()}

  @doc """
  The reservation holding `normalized_repo` back from `scope`'s creation
  path, or nil. Read by the creation guard once it ships.
  """
  @spec reservation(scope(), String.t() | nil) :: RepositoryReservation.t() | nil
  def reservation(scope, normalized_repo) when is_binary(normalized_repo) do
    Repo.one(
      from r in RepositoryReservation,
        where: ^scope_filter(scope),
        where: r.normalized_repo_full_name == ^normalized_repo,
        order_by: [asc: r.created_at],
        limit: 1
    )
  end

  def reservation(_scope, _normalized_repo), do: nil

  defp scope_filter({:workspace, id}), do: dynamic([r], r.workspace_id == ^id)

  defp scope_filter({:legacy, user_id}),
    do: dynamic([r], r.user_id == ^user_id and is_nil(r.workspace_id))

  defp scope_of(%Project{workspace_id: id}) when is_binary(id), do: {:workspace, id}
  defp scope_of(%Project{user_id: user_id}), do: {:legacy, user_id}

  @doc """
  Mark `duplicate_id` as the legacy duplicate of `canonical_id`, and reserve
  its repository for its owner.

  For a reviewed data migration and nothing else: no page or context door
  reaches this, which is ADR 0009's "only the reviewed migration can mark a
  legacy duplicate". The canonical project is the one created first, by the
  persisted `created_at`; equal timestamps are ambiguous and need the owner
  to decide, so they are refused rather than guessed. Marking the same
  pair twice is a no-op; marking an already-marked duplicate against a
  different canonical project is refused, as is a canonical project that is
  itself a marked duplicate. The duplicate keeps its ids, owner, members
  and machine.

  The reservation is scoped as the duplicate is: to its workspace when it
  has one, otherwise to its legacy owner (see `t:scope/0`).

  `canonical: :explicit` is for an operator task carrying an owner's
  decision that the *later* project is canonical (ADR 0009 phase 4a, the
  Ravi seed): it skips the creation-order check, and logs that it did.
  Every other check still applies.
  """
  @spec mark_legacy_duplicate(String.t(), String.t(), canonical: :first_created | :explicit) ::
          {:ok, Project.t()}
          | {:error,
             :not_found
             | :same_project
             | :different_repository
             | :ambiguous_order
             | :not_later
             | :already_marked
             | :canonical_is_duplicate}
  def mark_legacy_duplicate(duplicate_id, canonical_id, opts \\ [])

  def mark_legacy_duplicate(id, id, _opts), do: {:error, :same_project}

  def mark_legacy_duplicate(duplicate_id, canonical_id, opts) do
    order = Keyword.get(opts, :canonical, :first_created)

    # ownership: no door -- a reviewed migration's operator is the authority
    # here, never a signed-in person; see the doc above.
    Repo.transaction(fn ->
      # ownership: no door -- as above, the reviewed migration.
      rows =
        Repo.all(
          from p in Project,
            where: p.id in ^[duplicate_id, canonical_id],
            order_by: p.id,
            lock: "FOR UPDATE"
        )

      duplicate = Enum.find(rows, &(&1.id == duplicate_id))
      canonical = Enum.find(rows, &(&1.id == canonical_id))

      with {:ok, repo} <- same_repository(duplicate, canonical),
           :ok <- markable(duplicate, canonical),
           :ok <- later(duplicate, canonical, order) do
        mark(duplicate, canonical, repo)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp same_repository(nil, _canonical), do: {:error, :not_found}
  defp same_repository(_duplicate, nil), do: {:error, :not_found}

  defp same_repository(duplicate, canonical) do
    repo = repo_key(duplicate)

    if repo && repo == repo_key(canonical),
      do: {:ok, repo},
      else: {:error, :different_repository}
  end

  defp markable(_duplicate, %Project{legacy_duplicate_at: %DateTime{}}),
    do: {:error, :canonical_is_duplicate}

  defp markable(%Project{legacy_duplicate_at: nil}, _canonical), do: :ok

  defp markable(%Project{legacy_duplicate_of: id}, %Project{id: id}), do: :ok
  defp markable(_duplicate, _canonical), do: {:error, :already_marked}

  defp later(duplicate, canonical, :explicit) do
    Logger.warning(
      "Marking project #{duplicate.id} a legacy duplicate of #{canonical.id} by explicit " <>
        "canonical choice, not creation order"
    )

    :ok
  end

  defp later(duplicate, canonical, :first_created) do
    case DateTime.compare(duplicate.created_at, canonical.created_at) do
      :gt -> :ok
      :eq -> {:error, :ambiguous_order}
      :lt -> {:error, :not_later}
    end
  end

  defp mark(%Project{legacy_duplicate_at: %DateTime{}} = duplicate, _canonical, _repo),
    do: duplicate

  defp mark(duplicate, canonical, repo) do
    now = DateTime.utc_now()

    # ownership: no door -- the reviewed migration above; see `mark_legacy_duplicate/2`.
    {1, [marked]} =
      Repo.update_all(
        from(p in Project, where: p.id == ^duplicate.id, select: p),
        set: [
          legacy_duplicate_of: canonical.id,
          legacy_duplicate_at: now,
          normalized_repo_full_name: repo
        ]
      )

    {workspace_id, user_id} =
      case scope_of(duplicate) do
        {:workspace, id} -> {id, nil}
        {:legacy, id} -> {nil, id}
      end

    Repo.insert_all(
      RepositoryReservation,
      [
        %{
          id: Ecto.UUID.generate(),
          normalized_repo_full_name: repo,
          workspace_id: workspace_id,
          user_id: user_id,
          reserved_project_id: duplicate.id,
          canonical_project_id: canonical.id,
          reason: :legacy_duplicate,
          created_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: :reserved_project_id
    )

    marked
  end

  defp repo_key(%Project{} = project),
    do: project.normalized_repo_full_name || Project.normalize_repo(project.repo_full_name)

  # ── GitHub connections and the catalog (phase 4b) ─────────────────────

  @doc "Park a connect round trip under `key_hash`; sweeps rows older than `max_age_s`."
  @spec put_connect_state(String.t(), String.t(), String.t(), pos_integer()) :: :ok
  def put_connect_state(key_hash, workspace_id, user_id, max_age_s) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_s, :second)
    Repo.delete_all(from s in ConnectState, where: s.created_at < ^cutoff)

    Repo.insert!(%ConnectState{
      key_hash: key_hash,
      workspace_id: workspace_id,
      user_id: user_id,
      created_at: DateTime.utc_now()
    })

    :ok
  end

  @doc """
  Take a parked connect round trip: deleted in the same statement that
  finds it, so a replay finds nothing. Nil when absent or older than
  `max_age_s`.
  """
  @spec take_connect_state(String.t(), pos_integer()) :: ConnectState.t() | nil
  def take_connect_state(key_hash, max_age_s) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_s, :second)

    case Repo.delete_all(from(s in ConnectState, where: s.key_hash == ^key_hash, select: s)) do
      {1, [%ConnectState{created_at: at} = row]} ->
        if DateTime.compare(at, cutoff) == :lt, do: nil, else: row

      _ ->
        nil
    end
  end

  @doc """
  Bind `installation_id` to `workspace_id` on `user_id`'s word. Binding it
  again re-activates a revoked or suspended connection and clears its
  reason; the same installation bound to other workspaces is untouched.
  """
  @spec bind_installation(String.t(), integer(), String.t() | nil, String.t()) ::
          {:ok, Installation.t()}
  def bind_installation(workspace_id, installation_id, account_login, user_id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      Installation,
      [
        %{
          id: Ecto.UUID.generate(),
          workspace_id: workspace_id,
          installation_id: installation_id,
          account_login: account_login,
          connected_by_user_id: user_id,
          connected_at: now
        }
      ],
      on_conflict: [
        set: [
          account_login: account_login,
          connected_by_user_id: user_id,
          connected_at: now,
          revoked_at: nil,
          suspended_at: nil,
          status_reason: nil
        ]
      ],
      conflict_target: [:workspace_id, :installation_id]
    )

    {:ok,
     Repo.get_by!(Installation, workspace_id: workspace_id, installation_id: installation_id)}
  end

  @doc "A workspace's connections, live first, then by when they were connected."
  @spec installations(String.t()) :: [Installation.t()]
  def installations(workspace_id) do
    Repo.all(
      from i in Installation,
        where: i.workspace_id == ^workspace_id,
        order_by: [asc: not is_nil(i.revoked_at), asc: i.connected_at, asc: i.id]
    )
  end

  @doc """
  Record what a refresh learned about one connection, and replace its
  catalog rows with `repos` in the same transaction: an active connection's
  repositories as GitHub listed them, or none for a suspended or revoked
  one, so they leave the catalog with the reason shown beside it.
  """
  @spec record_refresh(Installation.t(), Installation.status(), String.t() | nil, [map()]) :: :ok
  def record_refresh(%Installation{} = installation, status, reason, repos) do
    now = DateTime.utc_now()

    stamps =
      case status do
        :active -> [suspended_at: nil, status_reason: nil]
        :suspended -> [suspended_at: installation.suspended_at || now, status_reason: reason]
        :revoked -> [revoked_at: installation.revoked_at || now, status_reason: reason]
      end

    rows =
      repos
      |> Enum.uniq_by(& &1.github_repo_id)
      |> Enum.map(&catalog_row(&1, installation, now))

    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.update_all(
          from(i in Installation, where: i.id == ^installation.id),
          set: [refreshed_at: now] ++ stamps
        )

        Repo.delete_all(
          from r in CatalogRepo, where: r.workspace_installation_id == ^installation.id
        )

        rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(CatalogRepo, &1))
        :ok
      end)

    :ok
  end

  defp catalog_row(repo, installation, now) do
    %{
      id: Ecto.UUID.generate(),
      workspace_id: installation.workspace_id,
      workspace_installation_id: installation.id,
      github_repo_id: repo.github_repo_id,
      full_name: repo.full_name,
      normalized_repo_full_name: Project.normalize_repo(repo.full_name),
      private: repo.private,
      default_branch: repo.default_branch,
      pushed_at: repo.pushed_at,
      refreshed_at: now
    }
  end

  @doc """
  The catalog: every repository a live connection of the workspace reached
  at its last refresh, one row per repository (a repository two connections
  both reach appears once, through the earlier connection), most recently
  pushed first.
  """
  @spec catalog(String.t()) :: [CatalogRepo.t()]
  def catalog(workspace_id) do
    Repo.all(
      from r in CatalogRepo,
        join: i in Installation,
        on: i.id == r.workspace_installation_id,
        where:
          r.workspace_id == ^workspace_id and is_nil(i.revoked_at) and is_nil(i.suspended_at),
        order_by: [asc: i.connected_at, asc: i.id],
        preload: [workspace_installation: i]
    )
    |> Enum.uniq_by(& &1.github_repo_id)
    |> Enum.sort_by(&(&1.pushed_at || ""), :desc)
  end

  @doc "The catalog row for a repository, by comparison name, or nil."
  @spec catalog_repo(String.t(), String.t()) :: CatalogRepo.t() | nil
  def catalog_repo(workspace_id, normalized) do
    workspace_id |> catalog() |> Enum.find(&(&1.normalized_repo_full_name == normalized))
  end

  @doc """
  The workspace's one project for a repository: live, not a legacy
  duplicate, matched by comparison name. The partial unique index
  `projects_workspace_repo` makes it at most one.
  """
  @spec canonical_project(String.t(), String.t()) :: Project.t() | nil
  def canonical_project(workspace_id, normalized) do
    # ownership: no door -- `Ravix.Workspaces.Repositories` asks after
    # `Access.workspace_grant/3` admitted the caller to this workspace.
    Repo.one(
      from p in Project,
        where:
          p.workspace_id == ^workspace_id and p.normalized_repo_full_name == ^normalized and
            is_nil(p.legacy_duplicate_at) and is_nil(p.archived_at) and
            is_nil(p.deletion_requested_at)
    )
  end

  @doc "The workspace's canonical projects by GitHub repository id."
  @spec canonical_projects_by_repo_id(String.t(), [integer()]) :: %{integer() => Project.t()}
  def canonical_projects_by_repo_id(_workspace_id, []), do: %{}

  def canonical_projects_by_repo_id(workspace_id, repo_ids) do
    # ownership: no door -- as `canonical_project/2`, behind `Access.workspace_grant/3`.
    Repo.all(
      from p in Project,
        where:
          p.workspace_id == ^workspace_id and p.github_repo_id in ^repo_ids and
            is_nil(p.legacy_duplicate_at) and is_nil(p.archived_at) and
            is_nil(p.deletion_requested_at)
    )
    |> Map.new(&{&1.github_repo_id, &1})
  end

  @doc "The workspace's canonical projects, keyed by comparison name."
  @spec canonical_projects(String.t()) :: %{String.t() => Project.t()}
  def canonical_projects(workspace_id) do
    # ownership: no door -- as `canonical_project/2`, behind `Access.workspace_grant/3`.
    Repo.all(
      from p in Project,
        where:
          p.workspace_id == ^workspace_id and not is_nil(p.normalized_repo_full_name) and
            is_nil(p.legacy_duplicate_at) and is_nil(p.archived_at) and
            is_nil(p.deletion_requested_at)
    )
    |> Map.new(&{&1.normalized_repo_full_name, &1})
  end

  @doc """
  The project `projects_workspace_repo` counts for a repository in a
  workspace, live or not: every row but a marked legacy duplicate. An
  archived or pending-deletion one still holds the slot, so admission must
  not provision a second.
  """
  @spec index_holder(String.t(), String.t()) :: Project.t() | nil
  def index_holder(workspace_id, normalized) do
    # ownership: no door -- as `canonical_project/2`, behind `Access.workspace_grant/3`.
    Repo.one(
      from p in Project,
        where:
          p.workspace_id == ^workspace_id and p.normalized_repo_full_name == ^normalized and
            is_nil(p.legacy_duplicate_at),
        limit: 1
    )
  end

  @doc "A canonical project by id, reread, or nil."
  @spec canonical_project_by_id(String.t()) :: Project.t() | nil
  def canonical_project_by_id(id) do
    # ownership: no door -- a project `Ravix.Workspaces.Repositories` already
    # found through the workspace, behind `Access.workspace_grant/3`, reread.
    Repo.one(from p in Project, where: p.id == ^id and is_nil(p.legacy_duplicate_at))
  end

  @doc "Record GitHub's numeric id on a project that did not have it yet."
  @spec set_github_repo_id(Project.t(), integer()) :: :ok
  def set_github_repo_id(%Project{id: id}, github_repo_id) do
    # ownership: no door -- a catalog refresh behind `Access.workspace_grant/3`.
    Repo.update_all(
      from(p in Project, where: p.id == ^id and is_nil(p.github_repo_id)),
      set: [github_repo_id: github_repo_id]
    )

    :ok
  end

  @doc """
  Follow a rename or transfer on GitHub: point a canonical project at the
  repository's new name, keeping its id and everything on it. Refused
  (`:taken`) when another canonical project of the workspace already has
  that name, which the unique index would refuse too.
  """
  @spec rename_repo(Project.t(), String.t()) :: {:ok, Project.t()} | {:error, :taken}
  def rename_repo(%Project{} = project, full_name) do
    normalized = Project.normalize_repo(full_name)

    # ownership: no door -- a catalog refresh or an admission, behind
    # `Access.workspace_grant/3`, following GitHub's own rename.
    project
    |> Ecto.Changeset.change(repo_full_name: full_name, normalized_repo_full_name: normalized)
    |> Ecto.Changeset.unique_constraint(:repo_full_name, name: :projects_workspace_repo)
    |> Repo.update()
    |> case do
      {:ok, project} -> {:ok, project}
      {:error, _changeset} -> {:error, :taken}
    end
  end

  # ── operator data steps (the Ravi seed) ───────────────────────────────
  #
  # `Ravix.Workspaces.RaviSeed` and nothing else: an operator's reviewed data
  # step, run as no user, which is its whole authorization.

  @doc """
  Live team workspaces called `name` in which any of `user_ids` holds a
  membership row, live or revoked, oldest first.
  """
  @spec team_workspaces_named(String.t(), [String.t()]) :: [Workspace.t()]
  def team_workspaces_named(name, user_ids) do
    Repo.all(
      from w in Workspace,
        as: :workspace,
        where:
          w.kind == :team and w.name == ^name and is_nil(w.archived_at) and
            exists(
              from m in Membership,
                where: m.workspace_id == parent_as(:workspace).id and m.user_id in ^user_ids,
                select: 1
            ),
        order_by: [asc: w.created_at, asc: w.id]
    )
  end

  @doc "`user_id`'s membership row in `workspace_id`, revoked or not, or nil."
  @spec membership_row(String.t(), String.t()) :: Membership.t() | nil
  def membership_row(workspace_id, user_id),
    do: Repo.get_by(Membership, workspace_id: workspace_id, user_id: user_id)

  @doc """
  Make `user_id` an owner of `workspace_id` unless they hold any membership
  row there already. The seed refuses first when that row is revoked, so
  this never reports somebody as an owner who is not one.
  """
  @spec ensure_owner(String.t(), String.t()) :: :ok
  def ensure_owner(workspace_id, user_id) do
    Repo.insert_all(
      Membership,
      [
        %{
          workspace_id: workspace_id,
          user_id: user_id,
          role: :owner,
          created_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  The live projects of `owner_ids` whose repository is under `org`
  (compared lowercased), oldest first, and the named projects in `ids`
  whatever their state, so the seed can say what is wrong with one.
  """
  @spec seed_projects([String.t()], String.t(), [String.t()]) :: [Project.t()]
  def seed_projects(owner_ids, org, ids) do
    prefix = String.downcase(org) <> "/%"

    # ownership: no door -- the operator data step above.
    Repo.all(
      from p in Project,
        where:
          p.id in ^ids or
            (p.user_id in ^owner_ids and is_nil(p.archived_at) and
               is_nil(p.deletion_requested_at) and
               like(
                 fragment("lower(btrim(?, E' \\t\\r\\n'))", p.repo_full_name),
                 ^prefix
               )),
        order_by: [asc: p.created_at, asc: p.id]
    )
  end

  @doc """
  Move a legacy project into `workspace_id`, filling its attribution. The
  legacy owner stays `user_id`, so every legacy door still admits whoever it
  admitted. A project already in a workspace is left alone (0).
  """
  @spec move_project(String.t(), String.t()) :: 0 | 1
  def move_project(project_id, workspace_id) do
    # ownership: no door -- the operator data step above.
    {count, _} =
      Repo.update_all(
        from(p in Project,
          where: p.id == ^project_id and is_nil(p.workspace_id),
          update: [
            set: [
              workspace_id: ^workspace_id,
              created_by_user_id: coalesce(p.created_by_user_id, p.user_id),
              normalized_repo_full_name:
                fragment(
                  "coalesce(?, nullif(lower(btrim(?, E' \\t\\r\\n')), ''))",
                  p.normalized_repo_full_name,
                  p.repo_full_name
                )
            ]
          ]
        ),
        []
      )

    if count == 1, do: attach_backing_installations(@attach_on_move, workspace_id)
    count
  end

  @doc "Rename a project. The operator data step only."
  @spec rename_project(String.t(), String.t()) :: 0 | 1
  def rename_project(project_id, name) do
    # ownership: no door -- the operator data step above.
    {count, _} =
      Repo.update_all(from(p in Project, where: p.id == ^project_id), set: [name: name])

    count
  end

  # ── the personal-workspace assignment (ADR 0009 follow-up) ────────────

  @doc """
  Every project with no workspace, with its legacy owner's login and live
  personal workspace (nil when they have none), oldest first. Archived,
  deleting and legacy-duplicate rows are included so the operator step can
  say it skipped them.
  """
  @spec unassigned_projects() :: [
          %{project: Project.t(), login: String.t() | nil, workspace_id: String.t() | nil}
        ]
  def unassigned_projects do
    # ownership: no door -- the operator data step `Ravix.Workspaces.PersonalAssignment`.
    Repo.all(
      from p in Project,
        left_join: u in User,
        on: u.id == p.user_id,
        left_join: w in Workspace,
        on: w.personal_user_id == p.user_id and w.kind == :personal and is_nil(w.archived_at),
        where: is_nil(p.workspace_id),
        order_by: [asc: p.created_at, asc: p.id],
        select: %{project: p, login: u.login, workspace_id: w.id}
    )
  end

  @doc """
  The project each of `workspace_ids` counts for a repository in
  `projects_workspace_repo` (every row but a marked legacy duplicate), as
  `{workspace_id, normalized_repo} => %{id: project_id, state: state}`,
  where `state` is `:live`, `:archived` or `:deleting`: an archived or
  deleting project still holds the slot.
  """
  @spec index_holders([String.t()]) :: %{
          {String.t(), String.t()} => %{id: String.t(), state: :live | :archived | :deleting}
        }
  def index_holders([]), do: %{}

  def index_holders(workspace_ids) do
    # ownership: no door -- the operator data step, as `unassigned_projects/0`.
    Repo.all(
      from p in Project,
        where:
          p.workspace_id in ^workspace_ids and not is_nil(p.normalized_repo_full_name) and
            is_nil(p.legacy_duplicate_at),
        order_by: [asc: p.created_at, asc: p.id],
        select: {{p.workspace_id, p.normalized_repo_full_name}, p}
    )
    |> Enum.reverse()
    |> Map.new(fn {key, project} -> {key, %{id: project.id, state: holder_state(project)}} end)
  end

  defp holder_state(%Project{archived_at: %DateTime{}}), do: :archived
  defp holder_state(%Project{deletion_requested_at: %DateTime{}}), do: :deleting
  defp holder_state(%Project{}), do: :live

  @doc """
  Put a legacy project into its owner's personal workspace, for the
  personal-workspace assignment. Written only while the row is still
  unassigned, live and not a marked duplicate, re-checked by the update
  itself: `:skipped` when it no longer is (0 rows), `:collision` when the
  workspace gained a project for its repository since the plan was made.
  """
  @spec assign_personal(String.t(), String.t()) :: :moved | :skipped | :collision
  def assign_personal(project_id, workspace_id) do
    # ownership: no door -- the operator data step `Ravix.Workspaces.PersonalAssignment`.
    {count, _} =
      Repo.update_all(
        from(p in Project,
          where:
            p.id == ^project_id and is_nil(p.workspace_id) and is_nil(p.archived_at) and
              is_nil(p.deletion_requested_at) and is_nil(p.legacy_duplicate_at),
          update: [
            set: [
              workspace_id: ^workspace_id,
              created_by_user_id: coalesce(p.created_by_user_id, p.user_id),
              normalized_repo_full_name:
                fragment(
                  "coalesce(?, nullif(lower(btrim(?, E' \\t\\r\\n')), ''))",
                  p.normalized_repo_full_name,
                  p.repo_full_name
                )
            ]
          ]
        ),
        []
      )

    if count == 1 do
      _ = attach_backing_installations(@attach_on_move, workspace_id)
      :moved
    else
      :skipped
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :unique_violation,
        do: :collision,
        else: reraise(error, __STACKTRACE__)
  end

  @doc "Which of `workspace_ids` are personal workspaces."
  @spec personal_ids([String.t()]) :: MapSet.t(String.t())
  def personal_ids(workspace_ids) do
    Repo.all(
      from w in Workspace, where: w.id in ^workspace_ids and w.kind == :personal, select: w.id
    )
    |> MapSet.new()
  end

  @doc """
  Move `project_id` from `from` (a workspace id, or nil for the legacy
  layout) into `to`, for its legacy owner `owner_id`. Under the project's
  row lock it re-checks that it is still that owner's, still in `from` and
  live, and that `to` has no project for its repository; the partial unique
  index answers a concurrent admission the same way. Tracks, threads,
  permission rows and legacy members are other tables' rows and stay as
  they are. The GitHub connection is `from`'s, so it is cleared, and the
  installation the project clones through is connected to `to` when
  `attach_backing_installations/2` allows it.
  """
  @spec move_owned_project(String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, Project.t()} | {:error, :not_found | {:taken, Project.t() | nil}}
  def move_owned_project(project_id, owner_id, from, to) do
    # ownership: `Ravix.Workspaces.move_project/3` went through
    # `Access.project_of/2` and `Access.workspace_grant/3` for `to`.
    Repo.transaction(fn ->
      # ownership: as above; the row is locked so the checks hold at the write.
      project =
        Repo.one(
          from p in Project,
            where:
              p.id == ^project_id and p.user_id == ^owner_id and is_nil(p.archived_at) and
                is_nil(p.deletion_requested_at) and is_nil(p.legacy_duplicate_at),
            lock: "FOR UPDATE"
        )

      with {:here, %Project{workspace_id: ^from}} <- {:here, project},
           normalized = repo_key(project),
           {:free, nil} <- {:free, normalized && index_holder(to, normalized)},
           {:ok, moved} <- put_workspace(project, to, normalized) do
        _ = attach_backing_installations(@attach_on_move, to)
        moved
      else
        {:free, %Project{} = holder} -> Repo.rollback({:taken, holder})
        {:here, _gone_or_moved} -> Repo.rollback(:not_found)
        # The failed statement aborted the transaction; the holder is read after.
        {:error, %Ecto.Changeset{}} -> Repo.rollback({:raced, repo_key(project)})
      end
    end)
    |> case do
      {:error, {:raced, normalized}} -> {:error, {:taken, index_holder(to, normalized)}}
      result -> result
    end
  end

  defp put_workspace(project, to, normalized) do
    project
    |> Ecto.Changeset.change(
      workspace_id: to,
      workspace_installation_id: nil,
      normalized_repo_full_name: normalized,
      created_by_user_id: project.created_by_user_id || project.user_id
    )
    |> Ecto.Changeset.unique_constraint(:normalized_repo_full_name,
      name: :projects_workspace_repo
    )
    |> Repo.update()
  end

  # ── the backfill ─────────────────────────────────────────────────────

  @doc """
  Run one backfill batch in its own transaction, bounded by `timeout_ms` of
  statement time, so a slow batch in `bin/migrate` fails that deploy step
  instead of holding locks against the serving release. A batch that fails
  rolls back whole; the next run resumes from it.
  """
  @spec bounded((-> result), pos_integer()) :: result when result: term()
  def bounded(batch, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    {:ok, result} =
      Repo.transaction(fn ->
        # `SET LOCAL`, parameterized: `true` scopes it to this transaction.
        Repo.query!("SELECT set_config('statement_timeout', $1, true)", ["#{timeout_ms}ms"])
        batch.()
      end)

    result
  end

  #
  # Each function is one bounded batch that selects only rows still missing
  # what it writes, so running it again -- after an interruption, on a second
  # instance at the same time, or after an old release inserted more rows --
  # picks up exactly what is left and returns 0 once there is nothing. That
  # anti-join is the resume point; there is no cursor to lose.

  @doc "Create personal workspaces for up to `limit` users without one. Returns the count."
  @spec insert_personal_workspaces(pos_integer()) :: non_neg_integer()
  def insert_personal_workspaces(limit) do
    now = DateTime.utc_now()

    # ownership: no door -- the release-time backfill, which runs as no user.
    missing =
      from u in User,
        as: :user,
        where:
          not exists(
            from w in Workspace, where: w.personal_user_id == parent_as(:user).id, select: 1
          ),
        order_by: u.id,
        limit: ^limit,
        select: %{
          id: fragment("gen_random_uuid()::text"),
          name: u.login,
          kind: "personal",
          personal_user_id: u.id,
          created_by_user_id: u.id,
          created_at: type(^now, :utc_datetime_usec)
        }

    {count, _} =
      Repo.insert_all(Workspace, missing,
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment, "(personal_user_id) WHERE personal_user_id IS NOT NULL"}
      )

    count
  end

  @doc """
  Give up to `limit` personal workspaces their owner's membership where no
  membership row exists at all. A revoked one is left revoked.
  """
  @spec insert_owner_memberships(pos_integer()) :: non_neg_integer()
  def insert_owner_memberships(limit) do
    now = DateTime.utc_now()

    missing =
      from w in Workspace,
        as: :workspace,
        where:
          w.kind == :personal and
            not exists(
              from m in Membership,
                where:
                  m.workspace_id == parent_as(:workspace).id and
                    m.user_id == parent_as(:workspace).personal_user_id,
                select: 1
            ),
        order_by: w.id,
        limit: ^limit,
        select: %{
          workspace_id: w.id,
          user_id: w.personal_user_id,
          role: "owner",
          created_at: type(^now, :utc_datetime_usec)
        }

    {count, _} = Repo.insert_all(Membership, missing, on_conflict: :nothing)
    count
  end

  @doc """
  Fill the equivalent-meaning fields on up to `limit` projects an older
  release inserted without them. Never touches `workspace_id`: moving a
  project into a workspace is an admission, not a backfill.
  """
  @spec fill_project_attribution(pos_integer()) :: non_neg_integer()
  def fill_project_attribution(limit) do
    # The SQL spelling of `Project.normalize_repo/1`: the same four
    # whitespace characters trimmed, then lowercased. GitHub names are ASCII,
    # where `lower/1` and `String.downcase/1` agree.
    # ownership: no door -- the release-time backfill, which runs as no user.
    pending =
      from p in Project,
        where:
          is_nil(p.created_by_user_id) or
            (is_nil(p.normalized_repo_full_name) and
               fragment("coalesce(btrim(?, E' \\t\\r\\n'), '') <> ''", p.repo_full_name)),
        order_by: p.id,
        limit: ^limit,
        select: p.id

    # ownership: no door -- the release-time backfill, which runs as no user.
    {count, _} =
      Repo.update_all(
        from(p in Project,
          where: p.id in subquery(pending),
          update: [
            set: [
              created_by_user_id: coalesce(p.created_by_user_id, p.user_id),
              normalized_repo_full_name:
                fragment(
                  "coalesce(?, nullif(lower(btrim(?, E' \\t\\r\\n')), ''))",
                  p.normalized_repo_full_name,
                  p.repo_full_name
                )
            ]
          ]
        ),
        []
      )

    count
  end

  @doc """
  Connect to a workspace, for up to `limit` pairs, the GitHub installations
  that already back one of its live projects (RAV-69). Returns the count.

  Phase 4b read the catalog from `workspace_installations`, but projects
  that were in a workspace before it (moved, assigned, seeded) came with
  only their own `installation_id`, so their workspace said no GitHub
  account was connected while their tracks cloned through it. An
  installation a project of the workspace already uses is no wider grant:
  every member already works on that project through it.

  Nothing else is connected. A pair that has any row at all -- revoked,
  suspended or live -- is left as it is, so a connection somebody revoked
  stays revoked. A **personal** account's installation is never connected
  to a team workspace this way: that is the owner's explicit "Add to
  workspace" (`Ravix.Workspaces.Connect.add/3`). The account is the
  repository's owner, and it is taken to be personal when it is the login
  of somebody who has signed in here.

  `workspace_id` narrows it to one workspace, for the moment a project
  moves in. Idempotent and safe beside a concurrent run: the anti-join
  selects only what is missing and the unique index takes the rest.
  """
  @spec attach_backing_installations(pos_integer(), String.t() | nil) :: non_neg_integer()
  def attach_backing_installations(limit, workspace_id \\ nil) do
    now = DateTime.utc_now()

    # ownership: no door -- the release-time backfill, which runs as no
    # user, or a project move whose caller already went through its door.
    missing =
      from p in Project,
        as: :project,
        join: w in Workspace,
        on: w.id == p.workspace_id and is_nil(w.archived_at),
        where:
          not is_nil(p.installation_id) and is_nil(p.archived_at) and
            is_nil(p.deletion_requested_at) and
            not exists(
              from i in Installation,
                where:
                  i.workspace_id == parent_as(:project).workspace_id and
                    i.installation_id == parent_as(:project).installation_id,
                select: 1
            ) and
            (w.kind == :personal or
               not exists(
                 from u in User,
                   where:
                     fragment("lower(?)", u.login) ==
                       fragment(
                         "lower(split_part(btrim(?, E' \\t\\r\\n'), '/', 1))",
                         parent_as(:project).repo_full_name
                       ),
                   select: 1
               )),
        distinct: [p.workspace_id, p.installation_id],
        order_by: [asc: p.created_at, asc: p.id],
        limit: ^limit,
        select: %{
          id: fragment("gen_random_uuid()::text"),
          workspace_id: p.workspace_id,
          installation_id: p.installation_id,
          account_login:
            fragment(
              "nullif(split_part(btrim(?, E' \\t\\r\\n'), '/', 1), '')",
              p.repo_full_name
            ),
          connected_by_user_id: p.user_id,
          connected_at: type(^now, :utc_datetime_usec)
        }

    missing =
      if workspace_id, do: where(missing, [p], p.workspace_id == ^workspace_id), else: missing

    {count, _} =
      Repo.insert_all(Installation, missing,
        on_conflict: :nothing,
        conflict_target: [:workspace_id, :installation_id]
      )

    count
  end
end
