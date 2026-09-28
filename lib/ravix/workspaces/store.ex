defmodule Ravix.Workspaces.Store do
  @moduledoc """
  The workspace rows, with nobody's permission established.

  Ids in, rows out, as `Ravix.Projects.Store` is. `Ravix.Workspaces` holds
  the scoped readers, `Ravix.Accounts.Access.workspace_access/2` is the door,
  and `Ravix.Workspaces.Backfill` drives the batch functions at the bottom.
  Nothing here is reachable from a page.
  """

  import Ecto.Query

  alias Ravix.Accounts.User
  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Workspaces.{Membership, RepositoryReservation, Workspace}

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
  The reservation holding `normalized_repo` back from a legacy owner's
  creation path, or nil. Read by the creation guard once it ships.
  """
  @spec legacy_reservation(String.t(), String.t() | nil) :: RepositoryReservation.t() | nil
  def legacy_reservation(user_id, normalized_repo) when is_binary(normalized_repo) do
    Repo.one(
      from r in RepositoryReservation,
        where:
          r.user_id == ^user_id and is_nil(r.workspace_id) and
            r.normalized_repo_full_name == ^normalized_repo,
        order_by: [asc: r.created_at],
        limit: 1
    )
  end

  def legacy_reservation(_user_id, _normalized_repo), do: nil

  @doc """
  Mark `duplicate_id` as the legacy duplicate of `canonical_id`, and reserve
  its repository for its owner.

  For a reviewed data migration and nothing else: no page or context door
  reaches this, which is ADR 0009's "only the reviewed migration can mark a
  legacy duplicate". The canonical project is the one created first, by the
  persisted `created_at`; equal timestamps are ambiguous and need the owner
  to decide, so they are refused rather than guessed. Marking twice is a
  no-op. The duplicate keeps its ids, owner, members and machine.
  """
  @spec mark_legacy_duplicate(String.t(), String.t()) ::
          {:ok, Project.t()}
          | {:error,
             :not_found | :same_project | :different_repository | :ambiguous_order | :not_later}
  def mark_legacy_duplicate(id, id), do: {:error, :same_project}

  def mark_legacy_duplicate(duplicate_id, canonical_id) do
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
           :ok <- later(duplicate, canonical) do
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

  defp later(duplicate, canonical) do
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

    Repo.insert_all(
      RepositoryReservation,
      [
        %{
          id: Ecto.UUID.generate(),
          normalized_repo_full_name: repo,
          workspace_id: duplicate.workspace_id,
          user_id: duplicate.user_id,
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

  # ── the backfill ─────────────────────────────────────────────────────
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
    # The SQL spelling of `Project.normalize_repo/1`. GitHub names are ASCII,
    # where `lower/1` and `String.downcase/1` agree.
    # ownership: no door -- the release-time backfill, which runs as no user.
    pending =
      from p in Project,
        where:
          is_nil(p.created_by_user_id) or
            (is_nil(p.normalized_repo_full_name) and
               fragment("coalesce(btrim(?), '') <> ''", p.repo_full_name)),
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
                  "coalesce(?, nullif(lower(btrim(?)), ''))",
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
end
