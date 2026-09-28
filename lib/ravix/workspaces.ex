defmodule Ravix.Workspaces do
  @moduledoc """
  Workspaces, read in both layouts (ADR 0009, phase 2).

  This release adds workspaces without letting anything authorize through
  them. Every project is still reached through `Ravix.Accounts.Access`'s
  legacy doors -- its owner, its members, its tracks -- whether or not it
  has a `workspace_id`, and a workspace membership grants nothing yet. What
  lives here is the reading side the later phases build on, written so that
  every row reads the same whichever release wrote it:

    * a project with no `workspace_id` is `:legacy`, never a default
      workspace's;
    * `created_by/1` and `repo_key/1` fall back to the legacy columns when an
      older release inserted the row without the new ones, or the backfill
      has not reached it yet;
    * a person the backfill has not reached has no personal workspace, and
      that is an answer (`{:error, :not_found}`), not an error.

  Phase 3a adds the access side without switching it on: sign-in writes a
  new person's personal workspace (`Ravix.Accounts.upsert_user/1`),
  `Ravix.Accounts.Access` names what each role may do, and `remove_member/3`
  revokes a membership and tells open pages. Anything a workspace role
  *grants* stays behind `Ravix.Config.workspace_access?/0`, which is off.
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Projects.Project
  alias Ravix.Workspaces.{Store, Workspace}

  @typedoc "Which layout a project is in. Legacy means legacy authorization."
  @type layout :: :legacy | {:workspace, String.t()}

  @doc "Whether a project belongs to a workspace yet. Nil means legacy, not default."
  @spec layout(Project.t()) :: layout()
  def layout(%Project{workspace_id: id}) when is_binary(id), do: {:workspace, id}
  def layout(%Project{}), do: :legacy

  @doc """
  Who created a project. The legacy owner when an older release wrote the
  row without attribution; the two are the same person for every row that
  exists before admission.
  """
  @spec created_by(Project.t()) :: String.t()
  def created_by(%Project{created_by_user_id: id}) when is_binary(id), do: id
  def created_by(%Project{user_id: id}), do: id

  @doc """
  The repository a project is the catalog entry for, in comparison form, or
  nil for a scratch project. Scratch projects sit outside the catalog.
  """
  @spec repo_key(Project.t()) :: String.t() | nil
  def repo_key(%Project{normalized_repo_full_name: key}) when is_binary(key), do: key
  def repo_key(%Project{repo_full_name: repo}), do: Project.normalize_repo(repo)

  @doc "Whether a project is a scratch project: no repository, no catalog entry."
  @spec scratch?(Project.t()) :: boolean()
  def scratch?(%Project{} = project), do: is_nil(repo_key(project))

  @doc """
  Whether a reviewed migration marked this project as a later-created
  duplicate. It keeps its legacy access; it is simply never the catalog's.
  """
  @spec legacy_duplicate?(Project.t()) :: boolean()
  def legacy_duplicate?(%Project{legacy_duplicate_at: %DateTime{}}), do: true
  def legacy_duplicate?(%Project{}), do: false

  @doc "The caller's personal workspace, or not found until the backfill reaches them."
  @spec personal_workspace(User.t()) :: {:ok, Workspace.t()} | {:error, :not_found}
  def personal_workspace(%User{id: user_id}) do
    case Store.personal_workspace(user_id) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end

  @doc "The workspaces the caller is an unrevoked member of, with their role in each."
  @spec list(User.t()) :: [%{workspace: Workspace.t(), role: Ravix.Workspaces.Membership.role()}]
  def list(%User{id: user_id}) do
    for {workspace, role} <- Store.workspaces_of(user_id),
        do: %{workspace: workspace, role: role}
  end

  @doc """
  One workspace the caller belongs to. Another person's workspace, a revoked
  membership and a made-up id all answer not found.
  """
  @spec get(User.t(), String.t()) ::
          {:ok, %{workspace: Workspace.t(), role: Ravix.Workspaces.Membership.role()}}
          | {:error, :not_found}
  def get(%User{} = user, workspace_id), do: Access.workspace_access(user, workspace_id)

  @doc """
  Remove `user_id` from a workspace. Owners and admins only; only an owner
  removes an owner, and never the last one.

  Revocation is never behind `Ravix.Config.workspace_access?/0`: taking
  access away is safe in either state. The membership is stamped revoked,
  and once that has committed every instance's subscribers are told on the
  workspace's hub topic, so an open page re-reads its access on the notice
  (`RavixWeb.Live.WorkspaceGuard`). A caller who is not a member, and a
  target who is not one, both answer not found.
  """
  @spec remove_member(User.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :last_owner | {:forbidden, String.t()}}
  def remove_member(%User{} = user, workspace_id, user_id) do
    with {:ok, %{workspace: workspace, role: role}} <- Access.workspace_access(user, workspace_id),
         :ok <- Access.require_capability(role, :manage_members),
         {:ok, _revoked} <- revoke(workspace.id, user_id, role) do
      Ravix.Hub.publish_workspace(workspace.id, :members)
    end
  end

  defp revoke(workspace_id, user_id, role) do
    case Store.revoke_membership(workspace_id, user_id, role) do
      {:error, :owner_only} ->
        {:error, {:forbidden, "Only an owner of this workspace can remove an owner."}}

      result ->
        result
    end
  end

  @doc """
  Whether a legacy duplicate holds `repo` back from the caller's legacy
  creation path. Read-only in this release: project creation does not
  consult it until the creation guard ships ahead of workspace admission.
  """
  @spec reserved_for?(User.t(), String.t() | nil) :: boolean()
  def reserved_for?(%User{id: user_id}, repo),
    do: not is_nil(Store.reservation({:legacy, user_id}, Project.normalize_repo(repo)))

  @doc """
  Whether a legacy duplicate holds `repo` back inside a workspace the caller
  belongs to. Read-only in this release, as `reserved_for?/2` is; a
  workspace the caller is not a member of answers not found.
  """
  @spec reserved_in?(User.t(), String.t(), String.t() | nil) ::
          {:ok, boolean()} | {:error, :not_found}
  def reserved_in?(%User{} = user, workspace_id, repo) do
    with {:ok, %{workspace: workspace}} <- Access.workspace_access(user, workspace_id) do
      reservation = Store.reservation({:workspace, workspace.id}, Project.normalize_repo(repo))
      {:ok, not is_nil(reservation)}
    end
  end
end
