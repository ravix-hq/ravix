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

  Phase 4a adds team workspaces behind the same switch: anybody signed in
  creates one and owns it (`create/2`), owners and admins invite by GitHub
  login (`invite/4`, `revoke_invite/3`), and owners set roles
  (`set_role/4`). An invitation for somebody not signed in here waits and
  is accepted at their sign-in. Projects still authorize through their
  legacy doors, wherever they sit.
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
  (`RavixWeb.Live.WorkspaceGuard`), and on each of its projects' topics
  (`:people`), so an open track page does too. A caller who is not a member, and a
  target who is not one, both answer not found. The caller's own role is
  checked again under the removal's lock, so one revoked at the same moment
  is refused.

  Do not call this inside an outer transaction: it publishes after its own
  commit, and inside another the notice would go out before the removal is
  visible, so subscribers would re-read the access they are about to lose.
  """
  @spec remove_member(User.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :last_owner | {:forbidden, String.t()}}
  def remove_member(%User{} = user, workspace_id, user_id) do
    with {:ok, %{workspace: workspace, role: role}} <- Access.workspace_access(user, workspace_id),
         :ok <- Access.require_capability(role, :manage_members),
         {:ok, _revoked} <- revoke(workspace.id, user_id, user.id) do
      members_changed(workspace.id)
    end
  end

  @doc """
  Tell open pages that a workspace's live members changed, after the change
  has committed: the workspace's own topic, and each of its projects'
  (`:people`), since a track page is subscribed to its project and, with
  `RAVIX_WORKSPACE_ACCESS` on, a membership may be what admits it -- as a
  project-member change does. A notice only; it grants and reads nothing.
  """
  @spec members_changed(String.t()) :: :ok
  def members_changed(workspace_id) do
    for project_id <- Store.project_ids(workspace_id),
        do: Ravix.Hub.publish(project_id, :people)

    Ravix.Hub.publish_workspace(workspace_id, :members)
  end

  defp revoke(workspace_id, user_id, actor_id) do
    case Store.revoke_membership(workspace_id, user_id, actor_id) do
      {:error, :actor_gone} ->
        {:error, :not_found}

      {:error, :not_manager} ->
        Access.require_capability(:member, :manage_members)

      {:error, :owner_only} ->
        {:error, {:forbidden, "Only an owner of this workspace can remove an owner."}}

      result ->
        result
    end
  end

  # ── team workspaces (phase 4a) ─────────────────────────────────────────

  @typedoc "Why a workspace people change was refused."
  @type reason ::
          :not_found
          | {:forbidden, String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | Ravix.GitHub.Error.t()

  @typedoc "A workspace's people, as its page shows them."
  @type people :: %{
          workspace: Workspace.t(),
          role: Ravix.Workspaces.Membership.role(),
          members: [%{user: User.t(), role: Ravix.Workspaces.Membership.role()}],
          invites: [Ravix.Workspaces.Invite.t()]
        }

  @roles %{"owner" => :owner, "admin" => :admin, "member" => :member}

  # GitHub's own rule for a login: letters, digits and single inner hyphens,
  # at most 39 characters.
  @login ~r/\A[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}\z/

  @doc "Whether the workspace UI and everything a workspace grants are switched on."
  @spec enabled?() :: boolean()
  def enabled?, do: Ravix.Config.workspace_access?()

  @doc "A role as a form spells it, or nil for anything else."
  @spec parse_role(term()) :: Ravix.Workspaces.Membership.role() | nil
  def parse_role(role) when is_atom(role) and role in [:owner, :admin, :member], do: role
  def parse_role(role) when is_binary(role), do: @roles[role]
  def parse_role(_role), do: nil

  @doc """
  Create a team workspace. Anybody signed in may, and becomes its one owner.
  Not found while `RAVIX_WORKSPACE_ACCESS` is off.
  """
  @spec create(User.t(), String.t() | nil) :: {:ok, Workspace.t()} | {:error, reason()}
  def create(%User{} = user, name) do
    name = name |> to_string() |> String.trim()

    with :ok <- Access.workspace_creation(user),
         :ok <- valid_name(name) do
      case Store.create_team_workspace(user.id, name) do
        {:ok, workspace} ->
          {:ok, workspace}

        {:error, _changeset} ->
          {:error, {:unprocessable, "name", "The workspace could not be created."}}
      end
    end
  end

  defp valid_name(""), do: {:error, {:unprocessable, "name", "Give the workspace a name."}}

  defp valid_name(name) do
    if String.length(name) <= 60,
      do: :ok,
      else: {:error, {:unprocessable, "name", "Keep the name to 60 characters."}}
  end

  @doc """
  A workspace's members and waiting invitations, for any live member of it.
  Not found for anybody else, and for everybody while the switch is off.
  """
  @spec people(User.t(), String.t()) :: {:ok, people()} | {:error, :not_found}
  def people(%User{} = user, workspace_id) do
    with true <- enabled?() || {:error, :not_found},
         {:ok, %{workspace: workspace, role: role}} <- Access.workspace_access(user, workspace_id) do
      {:ok,
       %{
         workspace: workspace,
         role: role,
         members: Store.members(workspace.id),
         invites: Store.invites(workspace.id)
       }}
    end
  end

  @doc """
  Invite somebody to a team workspace by GitHub login. Owners and admins.

  Somebody who has signed in here becomes a member at once. Anybody else
  gets an invitation that waits on their login, and on their GitHub id when
  GitHub can say it, and is accepted at their sign-in
  (`Ravix.Accounts.upsert_user/1`). A login GitHub says does not exist is
  refused; without a GitHub App to ask, the invitation waits on the login
  alone. Only an owner may invite somebody as an owner or admin, or change
  an invitation an owner sent (`Ravix.Workspaces.Invite.protected?/1`). There are
  no invite links and no guests: an invitation is a membership, or nothing.
  """
  @spec invite(User.t(), String.t(), String.t() | nil, term()) ::
          {:ok, :member | :invited} | {:error, reason()}
  def invite(%User{} = user, workspace_id, login, role \\ :member) do
    with {:ok, %{workspace: workspace, role: mine}} <-
           Access.workspace_grant(user, workspace_id, :manage_members),
         :ok <- team(workspace),
         {:ok, role} <- grantable(mine, parse_role(role)),
         {:ok, login} <- parse_login(login),
         {:ok, found} <- resolve_login(login) do
      invite_found(user, workspace, found, role)
    end
  end

  defp invite_found(user, workspace, %{user: %User{} = member}, role) do
    case Store.add_member(workspace.id, member.id, role, user.id) do
      :ok ->
        members_changed(workspace.id)
        {:ok, :member}

      {:error, :already_member} ->
        {:error, {:conflict, "already_member", "@#{member.login} is already in this workspace."}}
    end
  end

  defp invite_found(user, workspace, found, role) do
    attrs = %{
      workspace_id: workspace.id,
      login: found.login,
      github_id: found.github_id,
      avatar_url: found.avatar_url,
      role: role
    }

    case Store.put_invite(attrs, user.id) do
      {:ok, _invite} ->
        Ravix.Hub.publish_workspace(workspace.id, :members)
        {:ok, :invited}

      {:error, reason} ->
        invite_refused(reason)
    end
  end

  defp invite_refused(:actor_gone), do: {:error, :not_found}

  defp invite_refused(:owner_only),
    do:
      {:error,
       {:forbidden,
        "Only an owner can change or withdraw an invitation an owner sent, or one for an owner or admin."}}

  defp invite_refused(%Ecto.Changeset{}),
    do: {:error, {:unprocessable, "login", "The invitation could not be saved."}}

  @doc """
  Withdraw an invitation nobody has taken up yet. Owners and admins, except
  that only an owner withdraws one an owner sent or one for an owner or
  admin.
  """
  @spec revoke_invite(User.t(), String.t(), String.t() | nil) :: :ok | {:error, reason()}
  def revoke_invite(%User{} = user, workspace_id, login) do
    with {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :manage_members),
         {:ok, login} <- parse_login(login) do
      case Store.delete_invite(workspace.id, login, user.id) do
        :ok -> Ravix.Hub.publish_workspace(workspace.id, :members)
        {:error, :not_found} -> {:error, :not_found}
        {:error, reason} -> invite_refused(reason)
      end
    end
  end

  @doc """
  Change a member's role. Owners only, and never leaving the workspace
  without an owner.
  """
  @spec set_role(User.t(), String.t(), String.t(), term()) :: :ok | {:error, reason()}
  def set_role(%User{} = user, workspace_id, user_id, role) do
    with {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :manage_roles),
         {:ok, role} <- grantable(:owner, parse_role(role)) do
      case Store.set_role(workspace.id, user_id, role, user.id) do
        {:ok, _membership} ->
          Ravix.Hub.publish_workspace(workspace.id, :members)

        {:error, :last_owner} ->
          {:error, {:conflict, "last_owner", "A workspace needs at least one owner."}}

        {:error, :not_owner} ->
          Access.require_capability(:admin, :manage_roles)

        {:error, _gone} ->
          {:error, :not_found}
      end
    end
  end

  defp team(%Workspace{kind: :team}), do: :ok

  defp team(%Workspace{}),
    do:
      {:error,
       {:unprocessable, "personal",
        "A personal workspace is yours alone. Create a team workspace to invite people."}}

  defp grantable(_mine, nil), do: bad_role()
  defp grantable(_mine, :member), do: {:ok, :member}

  defp grantable(mine, role) do
    with :ok <- Access.require_capability(mine, :manage_roles), do: {:ok, role}
  end

  defp bad_role, do: {:error, {:unprocessable, "role", "Choose owner, admin or member."}}

  defp parse_login(raw) do
    login =
      case raw |> to_string() |> String.trim() do
        "@" <> rest -> String.trim(rest)
        login -> login
      end

    cond do
      login == "" -> {:error, {:unprocessable, "no_login", "Give a GitHub username."}}
      Regex.match?(@login, login) -> {:ok, login}
      true -> {:error, {:unprocessable, "bad_login", "That is not a GitHub username."}}
    end
  end

  # Whom a typed login names. With a GitHub App, GitHub answers first, by
  # numeric id, and the local user is found by that id: a login stored here
  # can be stale (its owner renamed, somebody else took the name), so
  # matching it locally would admit the wrong person. Only with no App to
  # ask is the stored login used, and failing that the invitation waits on
  # the login alone.
  defp resolve_login(login) do
    case Ravix.Providers.github() do
      {:ok, app} -> lookup_on_github(app, login)
      {:error, {:unconfigured, :github}} -> resolve_locally(login)
    end
  end

  defp lookup_on_github(app, login) do
    case Ravix.GitHub.user_by_login(app, login) do
      {:ok, nil} ->
        {:error, {:unprocessable, "no_such_user", "There is no GitHub user called @#{login}."}}

      {:ok, account} ->
        found(to_string(account.id), account.login, account.avatar_url)

      {:error, _} = error ->
        error
    end
  end

  defp resolve_locally(login) do
    # ownership: a login an owner or admin typed, after `invite/4` put them
    # through `Access.workspace_grant/3`; read to learn whom they mean.
    case Ravix.Accounts.Store.user_by_login(login) do
      %User{} = user -> {:ok, %{user: user}}
      nil -> {:ok, %{user: nil, github_id: nil, login: login, avatar_url: nil}}
    end
  end

  # The account GitHub named, if it has signed in here under any login.
  defp found(github_id, login, avatar_url) do
    # ownership: as `resolve_login/1`, behind `Access.workspace_grant/3` --
    # whom the typed login names.
    case Ravix.Accounts.Store.user_by_github_id(github_id) do
      %User{} = user ->
        {:ok, %{user: user}}

      nil ->
        {:ok, %{user: nil, github_id: github_id, login: login, avatar_url: avatar_url}}
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
