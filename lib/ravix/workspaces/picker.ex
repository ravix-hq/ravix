defmodule Ravix.Workspaces.Picker do
  @moduledoc """
  The New track repository list (RAV-10, ADR 0009 phase 4c).

  One list, for one workspace, with no organisation step:

    * **The current workspace.** The caller's current workspace, whose
      projects the page's rail already holds (`Ravix.Workspaces.current/2`).
      Without one, the workspace of the project New track was opened from,
      when the caller is a member of it; otherwise their personal workspace,
      which also holds their legacy (workspace-less) projects, so a person
      nobody has moved into a workspace sees exactly the projects they see
      today.
    * **Its repositories**: the canonical project of each repository in
      that workspace the caller may open a track in. Marked legacy
      duplicates are left out, and two legacy rows of one repository are
      shown once. Ordered by when the caller last opened a track there,
      most recent first, then alphabetically by `owner/repo`; a query
      narrows it to the `owner/repo` names containing it.
    * **Its scratch projects**: kept out of the repository list and its
      deduplication, and offered separately as "No repository (scratch)".
    * **Adding a repository**: the workspace catalog's repositories with no
      project yet (`Ravix.Workspaces.Repositories`), for owners and admins.

  Built from the rail the page already holds (`Ravix.Projects.list/2`), so
  it offers nothing the caller could not already open. Only drawn while
  `RAVIX_WORKSPACE_ACCESS` is on.
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Projects.View
  alias Ravix.Tracks.Store, as: Tracks
  alias Ravix.Workspaces
  alias Ravix.Workspaces.{Repositories, Workspace}

  @typedoc "A repository in the list: the project it opens, and when the caller last used it."
  @type entry :: %{project: View.t(), repo: String.t(), used_at: DateTime.t() | nil}

  @typedoc "A repository the workspace reaches with no project yet."
  @type addable :: %{repo: String.t(), private: boolean()}

  @type t :: %__MODULE__{
          workspace: Workspace.t() | nil,
          entries: [entry()],
          scratch: [View.t()],
          can_add: boolean(),
          query: String.t(),
          mode: :repos | :add,
          addable: [addable()] | nil,
          adding: String.t() | nil
        }

  defstruct workspace: nil,
            entries: [],
            scratch: [],
            can_add: false,
            query: "",
            mode: :repos,
            addable: nil,
            adding: nil

  @doc """
  The list for `user`, from the rail's `views`, anchored on the project New
  track was opened from (nil for the top button).

  `current` is the caller's current workspace (`Ravix.Workspaces.current/2`),
  when the page has scoped its rail to it: then `views` are that scope
  already, and the list is that workspace's whatever the anchor. Without one
  the workspace is the anchor's, as above.
  """
  @spec build(User.t(), [View.t()], View.t() | nil, Workspaces.entry() | nil) :: t()
  def build(%User{} = user, views, anchor, current \\ nil) do
    {workspace, role} =
      case current do
        %{workspace: %Workspace{} = workspace, role: role} -> {workspace, role}
        nil -> workspace_for(user, anchor)
      end

    candidates =
      Enum.filter(views, &(&1.access != :tracks and (current != nil or in_scope?(&1, workspace))))

    # ownership: the project ids are the caller's own rail (`Projects.list/2`,
    # which admitted each through `Access.access_of/3`); only their own
    # tracks' times are read, to order the list.
    used = Tracks.last_used(user.id, Enum.map(candidates, & &1.id))
    {repos, scratch} = Enum.split_with(candidates, &is_binary(&1.repo))

    %__MODULE__{
      workspace: workspace,
      entries: entries(repos, used),
      scratch: Enum.sort_by(scratch, &{recency(used[&1.id]), String.downcase(&1.name)}),
      can_add: workspace != nil and Access.can?(role, :create_project)
    }
  end

  defp workspace_for(user, %View{workspace_id: id}) when is_binary(id) do
    case Workspaces.get(user, id) do
      {:ok, %{workspace: workspace, role: role}} -> {workspace, role}
      {:error, :not_found} -> workspace_for(user, nil)
    end
  end

  defp workspace_for(user, _anchor) do
    with {:ok, workspace} <- Workspaces.personal_workspace(user),
         {:ok, %{role: role}} <- Workspaces.get(user, workspace.id) do
      {workspace, role}
    else
      _ -> {nil, nil}
    end
  end

  # A personal workspace holds the caller's legacy projects too; a team
  # workspace only its own.
  defp in_scope?(%View{workspace_id: nil}, workspace),
    do: is_nil(workspace) or workspace.kind == :personal

  defp in_scope?(%View{workspace_id: id}, %Workspace{id: id}), do: true
  defp in_scope?(%View{}, _workspace), do: false

  defp entries(views, used) do
    views
    |> Enum.reject(& &1.legacy_duplicate)
    |> Enum.map(&%{project: &1, repo: &1.repo, used_at: used[&1.id]})
    # One entry per repository: the one used most recently, then the
    # caller's own, then the oldest.
    |> Enum.sort_by(&{recency(&1.used_at), &1.project.access != :owner, &1.project.created_at})
    |> Enum.uniq_by(&String.downcase(&1.repo))
    |> Enum.sort_by(&{recency(&1.used_at), String.downcase(&1.repo)})
  end

  # Most recent first; never used last.
  defp recency(nil), do: {1, 0}
  defp recency(%DateTime{} = at), do: {0, -DateTime.to_unix(at, :microsecond)}

  @doc "The entries whose `owner/repo` contains the query, case-insensitively, in list order."
  @spec matches(t()) :: [entry()]
  def matches(%__MODULE__{entries: entries, query: query}) do
    case query |> String.trim() |> String.downcase() do
      "" -> entries
      q -> Enum.filter(entries, &String.contains?(String.downcase(&1.repo), q))
    end
  end

  @doc "The repositories to add, narrowed by the query as `matches/1` narrows entries."
  @spec addable_matches(t()) :: [addable()]
  def addable_matches(%__MODULE__{addable: nil}), do: []

  def addable_matches(%__MODULE__{addable: addable, query: query}),
    do: filter_repos(addable, query)

  @doc """
  Repositories (`%{repo: "owner/repo"}` maps) whose name contains the query,
  case-insensitively, in the order given. The list the picker draws, here
  and in the Danger zone's Change repository (RAV-76).
  """
  @spec filter_repos([%{required(:repo) => String.t()}], String.t() | nil) :: [map()]
  def filter_repos(repos, query) do
    case (query || "") |> String.trim() |> String.downcase() do
      "" -> repos
      q -> Enum.filter(repos, &String.contains?(String.downcase(&1.repo), q))
    end
  end

  @doc """
  The project to preselect: the one New track was opened from, when it is
  in the list (or is one of its scratch projects); otherwise the most
  recently used repository; otherwise the first scratch project.
  """
  @spec preselect(t(), View.t() | nil) :: View.t() | nil
  def preselect(%__MODULE__{} = picker, anchor) do
    listed = Enum.map(picker.entries, & &1.project) ++ picker.scratch

    (anchor && Enum.find(listed, &(&1.id == anchor.id))) ||
      (match?([_ | _], picker.entries) && hd(picker.entries).project) ||
      List.first(picker.scratch)
  end

  @doc """
  Fill in the repositories the workspace reaches with no project yet, from
  the cached catalog: most recently pushed first. Owners and admins only.
  """
  @spec load_addable(t(), User.t()) :: t()
  def load_addable(%__MODULE__{can_add: true, workspace: %Workspace{} = workspace} = picker, user) do
    addable =
      case Repositories.catalog(user, workspace.id) do
        {:ok, %{repos: repos}} ->
          for %{repo: repo, project: nil} <- repos,
              do: %{repo: repo.full_name, private: repo.private}

        {:error, _} ->
          []
      end

    %{picker | addable: addable}
  end

  def load_addable(%__MODULE__{} = picker, _user), do: %{picker | addable: []}
end
