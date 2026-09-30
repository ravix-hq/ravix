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

  @typedoc "A workspace the caller belongs to, and their role in it."
  @type entry :: %{workspace: Workspace.t(), role: Ravix.Workspaces.Membership.role()}

  @doc """
  The caller's current workspace: what the sidebar, quick-jump, badges, the
  Inbox and New track are scoped to.

  The one they last chose (`Ravix.Accounts.put_current_workspace/2`), read
  again through `Access.workspace_access/2` every time, so a membership
  revoked or a workspace archived since then is never current. Failing
  that -- never chosen, or removed from the one they chose -- the default:
  their own personal workspace (RAV-33), and only for somebody without one
  their first team workspace.
  Not found for somebody in no workspace at all, and for everybody while
  `RAVIX_WORKSPACE_ACCESS` is off, which is what leaves the page unscoped.

  `listed` is `list/1`'s answer when the caller already has it in hand.
  """
  @spec current(User.t(), [entry()] | nil) :: {:ok, entry()} | {:error, :not_found}
  def current(%User{} = user, listed \\ nil) do
    with true <- enabled?() || {:error, :not_found} do
      case is_binary(user.current_workspace_id) &&
             Access.workspace_access(user, user.current_workspace_id) do
        {:ok, entry} -> {:ok, entry}
        _ -> default(user, listed || list(user))
      end
    end
  end

  defp default(user, listed) do
    case Enum.find(listed, &own_personal?(&1, user)) ||
           Enum.find(listed, &(&1.workspace.kind == :team)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  # The caller's own personal workspace: a membership of somebody else's
  # counts as any other workspace they were let into.
  defp own_personal?(%{workspace: workspace}, %User{id: user_id}),
    do: workspace.kind == :personal and workspace.personal_user_id == user_id

  defp own_personal_id(listed, user),
    do: Enum.find_value(listed, &(own_personal?(&1, user) && &1.workspace.id))

  @typedoc "Which part of a scoped page a project belongs to. See `partition/4`."
  @type placement :: :current | :shared | :other

  @doc """
  Where each of the caller's projects sits relative to their current
  workspace. `views` are what `Ravix.Projects.list/2` answered, so every
  one of them is already a project the caller reaches; this only sorts
  them, and it grants and hides nothing that access has not already decided.

    * A project in a workspace the caller is a member of belongs to that
      workspace: `:current` there, `:other` anywhere else.
    * Everything else -- a legacy project with no workspace, or one in a
      workspace the caller is not in, reached through a legacy project or
      track share -- belongs to their personal workspace. There their own
      projects are `:current`, and the ones somebody else shared with them
      are `:shared`, until the owner moves them into a workspace the caller
      is in.
    * A project with nowhere to belong, because the caller has no personal
      workspace yet, stays `:current` wherever they are: never hidden.

  With no current workspace (switch off, or no workspace at all) every
  project is `:current`.
  """
  @spec partition(User.t(), Workspace.t() | nil, [entry()], [map()]) :: %{
          current: [map()],
          shared: [map()],
          other: [map()]
        }
  def partition(%User{}, nil, _listed, views), do: %{current: views, shared: [], other: []}

  def partition(%User{} = user, %Workspace{} = current, listed, views) do
    member = MapSet.new(listed, & &1.workspace.id)
    personal = own_personal_id(listed, user)
    grouped = Enum.group_by(views, &placement(&1, current, member, personal))

    %{
      current: Map.get(grouped, :current, []),
      shared: Map.get(grouped, :shared, []),
      other: Map.get(grouped, :other, [])
    }
  end

  @doc """
  The workspace a project belongs to for this caller, as `partition/4`
  places it: its own when they are a member, else their personal one. Nil
  when it has no home among `listed`.
  """
  @spec home(User.t(), [entry()], map()) :: String.t() | nil
  def home(%User{} = user, listed, %{workspace_id: workspace_id}) do
    if Enum.any?(listed, &(&1.workspace.id == workspace_id)),
      do: workspace_id,
      else: own_personal_id(listed, user)
  end

  defp placement(view, current, member, personal) do
    cond do
      is_binary(view.workspace_id) and MapSet.member?(member, view.workspace_id) ->
        if view.workspace_id == current.id, do: :current, else: :other

      is_nil(personal) ->
        :current

      personal != current.id ->
        :other

      view.access == :owner ->
        :current

      true ->
        :shared
    end
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

  @doc """
  Rename a workspace. Owners and admins (`:rename_workspace`), of a team
  workspace or their personal one alike; its kind never changes. Open pages
  hear it as a members notice, which is what re-reads the switcher.
  """
  @spec rename(User.t(), String.t(), String.t() | nil) ::
          {:ok, Workspace.t()} | {:error, reason()}
  def rename(%User{} = user, workspace_id, name) do
    name = name |> to_string() |> String.trim()

    with {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :rename_workspace),
         :ok <- valid_name(name) do
      case Store.rename_workspace(workspace.id, name) do
        {:ok, workspace} ->
          Ravix.Hub.publish_workspace(workspace.id, :members)
          {:ok, workspace}

        {:error, :not_found} ->
          {:error, :not_found}
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

  # ── the Projects and Danger zone pages (RAV-73) ───────────────────────

  @typedoc "One row of a workspace's Projects page."
  @type project_row :: %{project: Project.t(), owner: User.t(), people: pos_integer()}

  @doc """
  Every live project in a workspace, with its owner and how many people
  reach it: the workspace's live members, who each have Write, and anybody
  else granted it directly, the owner included. Any live member; not found
  for anybody else, and for everybody while the switch is off.
  """
  @spec projects(User.t(), String.t()) :: {:ok, [project_row()]} | {:error, :not_found}
  def projects(%User{} = user, workspace_id) do
    with true <- enabled?() || {:error, :not_found},
         {:ok, %{workspace: workspace}} <- Access.workspace_access(user, workspace_id) do
      rows = Store.projects(workspace.id)
      members = MapSet.new(Store.members(workspace.id), & &1.user.id)
      direct = rows |> Enum.map(&elem(&1, 0).id) |> Store.direct_member_ids()

      {:ok,
       for {project, owner} <- rows do
         people =
           [owner.id | Map.get(direct, project.id, [])]
           |> MapSet.new()
           |> MapSet.union(members)
           |> MapSet.size()

         %{project: project, owner: owner, people: people}
       end}
    end
  end

  @doc """
  Leave a workspace. Any live member, except from their own personal
  workspace, and never its last owner. Like `remove_member/3`, taking
  access away is not behind `Ravix.Config.workspace_access?/0`, and open
  pages are told once it has committed.
  """
  @spec leave(User.t(), String.t()) :: :ok | {:error, reason()}
  def leave(%User{} = user, workspace_id) do
    with {:ok, %{workspace: workspace}} <- Access.workspace_access(user, workspace_id),
         :ok <- not_own_personal(workspace, user) do
      case Store.leave(workspace.id, user.id) do
        {:ok, _revoked} ->
          members_changed(workspace.id)

        {:error, :last_owner} ->
          {:error,
           {:conflict, "last_owner",
            "You are this workspace's only owner. Make somebody else an owner first, or delete the workspace."}}

        {:error, _gone} ->
          {:error, :not_found}
      end
    end
  end

  defp not_own_personal(%Workspace{kind: :personal, personal_user_id: id}, %User{id: id}),
    do: {:error, {:unprocessable, "personal", "You cannot leave your personal workspace."}}

  defp not_own_personal(_workspace, _user), do: :ok

  @doc """
  Delete a team workspace: owners only (`:delete_workspace`), with its name
  typed as `confirmation`, and only once no live project is left in it. The
  workspace is archived, so every door answers not found for it from then
  on; open pages hear a members notice and leave.
  """
  @spec delete(User.t(), String.t(), String.t() | nil) :: :ok | {:error, reason()}
  def delete(%User{} = user, workspace_id, confirmation) do
    with {:ok, %{workspace: workspace}} <-
           Access.workspace_grant(user, workspace_id, :delete_workspace),
         :ok <- deletable(workspace),
         :ok <- confirmed(workspace, confirmation) do
      case Store.archive_workspace(workspace.id, user.id) do
        {:ok, _archived} ->
          members_changed(workspace.id)

        {:error, {:has_projects, count}} ->
          {:error,
           {:conflict, "has_projects",
            "#{workspace.name} still has #{count} #{if count == 1, do: "project", else: "projects"}. Move or delete them first."}}

        {:error, :not_owner} ->
          Access.require_capability(:admin, :delete_workspace)

        {:error, _gone} ->
          {:error, :not_found}
      end
    end
  end

  defp deletable(%Workspace{kind: :team}), do: :ok

  defp deletable(%Workspace{}),
    do: {:error, {:unprocessable, "personal", "A personal workspace cannot be deleted."}}

  defp confirmed(%Workspace{name: name}, typed) do
    if is_binary(typed) and String.trim(typed) == name,
      do: :ok,
      else: {:error, {:unprocessable, "confirm", "Type the workspace's name to delete it."}}
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

  # ── moving a project between workspaces ───────────────────────────────

  @typedoc "Where a project's owner may move it, from `move_targets/2`."
  @type move_targets :: %{
          current: Workspace.t() | nil,
          targets: [Workspace.t()],
          duplicate_of: String.t() | nil
        }

  @doc """
  The workspace a project is in (nil for a legacy project) and the ones its
  owner may move it into: live workspaces where they are an owner or admin
  (`:manage_projects`), other than the current one. None for a legacy
  duplicate, which `move_project/3` refuses; `duplicate_of` names its
  canonical project. The project's owner only, and not found for everybody
  while `RAVIX_WORKSPACE_ACCESS` is off.
  """
  @spec move_targets(User.t(), String.t()) :: {:ok, move_targets()} | {:error, :not_found}
  def move_targets(%User{} = user, project_id) do
    with true <- enabled?() || {:error, :not_found},
         {:ok, project} <- Access.project_of(user, project_id) do
      targets =
        for {workspace, role} <- Store.workspaces_of(user.id),
            not legacy_duplicate?(project),
            workspace.id != project.workspace_id,
            Access.can?(role, :manage_projects),
            do: workspace

      {:ok,
       %{
         current: Store.live_workspace(project.workspace_id),
         targets: targets,
         duplicate_of: project.legacy_duplicate_of
       }}
    end
  end

  @doc """
  Move a project into another workspace, keeping its tracks.

  Its owner only (`Access.project_of/2`), and only into a workspace where
  they are an owner or admin (`Access.workspace_grant/3` with
  `:manage_projects`); a member-only workspace is refused. A target that
  already has a project for the same repository is refused with that
  project, so the caller can point to it (the one-project-per-repository
  index, `projects_workspace_repo`). A marked legacy duplicate is refused
  too: that index does not count it, so a moved duplicate would reserve
  nothing in its target and leave two projects for one repository there.

  Tracks, threads, legacy project and track members and permission rows
  stay as they are. A permission row counts only in the workspace it was
  granted in, so a private track stays private: after the move it admits
  its creator and legacy members, and the target's members see only its
  workspace-visible tracks.

  After the move has committed, both workspaces' pages and every project in
  them are told (`members_changed/1`), so open rails and track pages
  re-read who can reach what. Do not call this inside an outer transaction.
  """
  @spec move_project(User.t(), String.t(), String.t()) ::
          {:ok, Project.t()}
          | {:error,
             :not_found
             | {:forbidden, String.t()}
             | {:conflict, String.t(), String.t()}
             | {:repository_taken, %{id: String.t(), name: String.t(), workspace: String.t()}}}
  def move_project(%User{} = user, project_id, workspace_id) do
    with {:ok, project} <- Access.project_of(user, project_id),
         {:ok, %{workspace: target}} <-
           Access.workspace_grant(user, workspace_id, :manage_projects),
         :ok <- not_duplicate(project),
         :ok <- elsewhere(project, target),
         {:ok, moved} <- store_move(project, target) do
      if project.workspace_id, do: members_changed(project.workspace_id)
      members_changed(target.id)
      {:ok, moved}
    end
  end

  defp not_duplicate(%Project{legacy_duplicate_of: canonical} = project) do
    if legacy_duplicate?(project),
      do:
        {:error,
         {:conflict, "legacy_duplicate",
          "This project is a legacy duplicate of project #{canonical}, so it cannot be moved. " <>
            "Keep working in that one, or ask for the duplicate to be resolved first."}},
      else: :ok
  end

  defp elsewhere(%Project{workspace_id: id}, %Workspace{id: id, name: name}),
    do: {:error, {:conflict, "same_workspace", "The project is already in #{name}."}}

  defp elsewhere(%Project{}, %Workspace{}), do: :ok

  defp store_move(project, target) do
    case Store.move_owned_project(project.id, project.user_id, project.workspace_id, target.id) do
      {:ok, moved} ->
        {:ok, moved}

      {:error, {:taken, %Project{} = holder}} ->
        {:error, {:repository_taken, %{id: holder.id, name: holder.name, workspace: target.name}}}

      {:error, {:taken, nil}} ->
        {:error,
         {:conflict, "repository_taken",
          "#{target.name} already has a project for this repository."}}

      # Moved, archived or deleted by somebody else since it was read.
      {:error, :not_found} ->
        {:error, :not_found}
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
