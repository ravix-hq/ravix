defmodule Ravix.Projects.Sections do
  @moduledoc """
  Personal sidebar organization; never changes a project's owner or access.

  A section belongs to one person in one of their workspaces (RAV-127):
  nobody else sees it, and it holds only projects of that workspace. The
  workspace in hand is read again through `Access.workspace_access/2` on
  every call, so an id from the browser, another person's workspace or a
  membership revoked since all answer not found. A section the previous
  release wrote without a workspace is read as the person's personal
  workspace until `Ravix.Workspaces.Backfill` has filled it in.

  With no workspace in hand -- the page unscoped while
  `RAVIX_WORKSPACE_ACCESS` is off -- every section of the person's is
  listed and any of them takes any project they reach, as before.
  """
  import Ecto.Query

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Projects
  alias Ravix.Projects.{ClosedView, Section, SectionPlacement}
  alias Ravix.Repo
  alias Ravix.Workspaces

  @typedoc "The current workspace's id, or nil for the unscoped page."
  @type scope :: String.t() | nil

  @doc """
  The caller's sections in `workspace_id`, and which of their projects sits
  in which. Nil lists every section of theirs.
  """
  @spec list(User.t(), scope()) :: {:ok, {[Section.t()], map()}} | {:error, :not_found}
  def list(%User{id: user_id} = user, workspace_id) do
    with {:ok, scope} <- scope(user, workspace_id) do
      sections =
        Repo.all(
          from s in Section,
            as: :section,
            where: s.user_id == ^user_id,
            where: ^scope,
            order_by: [s.name, s.id]
        )

      placements =
        Repo.all(
          from p in SectionPlacement,
            join: s in Section,
            as: :section,
            on: s.id == p.section_id and s.user_id == p.user_id,
            where: p.user_id == ^user_id,
            where: ^scope,
            select: {p.project_id, p.section_id}
        )

      {:ok, {sections, Map.new(placements)}}
    end
  end

  @doc """
  Create a personal section in `workspace_id`. With nil, the unscoped page,
  it still lands in the caller's personal workspace, so this release writes
  no workspace-less row of its own.
  """
  @spec create(User.t(), scope(), map()) ::
          {:ok, Section.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create(%User{id: user_id} = user, workspace_id, attrs) do
    with {:ok, home} <- home(user, workspace_id) do
      %Section{user_id: user_id, workspace_id: home} |> Section.changeset(attrs) |> Repo.insert()
    end
  end

  @doc "Rename or collapse a personal section."
  @spec update(User.t(), String.t(), map()) :: {:ok, Section.t()} | {:error, term()}
  def update(user, id, attrs) do
    with {:ok, section} <- fetch(user, id) do
      section |> Section.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Remove a section; its projects return to the unsectioned list."
  @spec delete(User.t(), String.t()) :: {:ok, Section.t()} | {:error, term()}
  def delete(user, id) do
    with {:ok, section} <- fetch(user, id), do: Repo.delete(section)
  end

  @doc """
  Move an accessible project into a personal section, or out with an empty
  id. With a workspace in hand, the section and the project must both be
  that workspace's: a section of another workspace, or a project that
  belongs elsewhere, is refused as `{:conflict, "other_workspace", _}`.
  """
  @spec move(User.t(), scope(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def move(%User{} = user, workspace_id, project_id, section_id) do
    with {:ok, project} <- Projects.get(user, project_id) do
      place(user, workspace_id, project, section_id)
    end
  end

  @doc "The projects whose closed tracks this person asked to see."
  @spec closed_shown(User.t()) :: [String.t()]
  def closed_shown(%User{id: user_id}),
    do: Repo.all(from v in ClosedView, where: v.user_id == ^user_id, select: v.project_id)

  @doc """
  Show or hide a project's closed tracks in this person's sidebar. Somebody
  invited only to tracks has no project row menu, and no closed track to open.
  """
  @spec show_closed(User.t(), String.t(), boolean()) :: {:ok, boolean()} | {:error, term()}
  def show_closed(%User{id: user_id} = user, project_id, show?) do
    case Projects.get(user, project_id) do
      {:ok, %{access: access}} when access != :tracks ->
        if show?,
          do:
            Repo.insert_all(ClosedView, [%{user_id: user_id, project_id: project_id}],
              on_conflict: :nothing
            ),
          else:
            Repo.delete_all(
              from v in ClosedView, where: v.user_id == ^user_id and v.project_id == ^project_id
            )

        {:ok, show?}

      _ ->
        {:error, :not_found}
    end
  end

  defp place(%User{id: user_id}, _workspace_id, %{id: project_id}, "") do
    Repo.delete_all(
      from p in SectionPlacement, where: p.user_id == ^user_id and p.project_id == ^project_id
    )

    {:ok, nil}
  end

  defp place(%User{id: user_id} = user, workspace_id, project, section_id) do
    with {:ok, section} <- fetch(user, section_id),
         :ok <- same_workspace(user, workspace_id, section, project) do
      %SectionPlacement{user_id: user_id, project_id: project.id, section_id: section.id}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:section_id)
      |> Repo.insert(
        on_conflict: {:replace, [:section_id]},
        conflict_target: [:user_id, :project_id]
      )
    end
  end

  # Unscoped: any section of the caller's takes any project they reach.
  defp same_workspace(_user, nil, _section, _project), do: :ok

  # The section's workspace (nil read as personal) and the project's home
  # for this caller (`Workspaces.home/3`: its own workspace when they are a
  # member there, else their personal one) must both be the current one.
  defp same_workspace(user, workspace_id, section, project) do
    with {:ok, %{workspace: current}} <- Access.workspace_access(user, workspace_id) do
      listed = Workspaces.list(user)
      personal = personal_id(user)

      cond do
        (section.workspace_id || personal) != current.id ->
          {:error, {:conflict, "other_workspace", "That section is in another workspace."}}

        Workspaces.home(user, listed, project) != current.id ->
          {:error, {:conflict, "other_workspace", "That project is in another workspace."}}

        true ->
          :ok
      end
    end
  end

  # Which sections the page shows: all of them unscoped; in a workspace, its
  # own, plus the rows still without one when it is the caller's personal
  # workspace, which is what the previous release's rows mean.
  defp scope(_user, nil), do: {:ok, true}

  defp scope(%User{id: user_id} = user, workspace_id) do
    with {:ok, %{workspace: workspace}} <- Access.workspace_access(user, workspace_id) do
      if workspace.kind == :personal and workspace.personal_user_id == user_id,
        do:
          {:ok, dynamic([section: s], s.workspace_id == ^workspace.id or is_nil(s.workspace_id))},
        else: {:ok, dynamic([section: s], s.workspace_id == ^workspace.id)}
    end
  end

  defp home(user, nil), do: {:ok, personal_id(user)}

  defp home(user, workspace_id) do
    with {:ok, %{workspace: workspace}} <- Access.workspace_access(user, workspace_id),
         do: {:ok, workspace.id}
  end

  # Nil only for somebody the personal-workspace backfill has not reached.
  defp personal_id(user) do
    case Workspaces.personal_workspace(user) do
      {:ok, workspace} -> workspace.id
      {:error, :not_found} -> nil
    end
  end

  defp fetch(%User{id: user_id}, id) do
    case Repo.one(from s in Section, where: s.user_id == ^user_id and s.id == ^id) do
      nil -> {:error, :not_found}
      section -> {:ok, section}
    end
  end
end
