defmodule Ravix.Projects.Sections do
  @moduledoc "Personal sidebar organization; never changes a project's owner or access."
  import Ecto.Query

  alias Ravix.Accounts.User
  alias Ravix.Projects
  alias Ravix.Projects.{ClosedView, Section, SectionPlacement}
  alias Ravix.Repo

  @doc "Sections and project assignments belonging only to the current person."
  @spec list(User.t()) :: {[Section.t()], map()}
  def list(%User{id: user_id}) do
    sections = Repo.all(from s in Section, where: s.user_id == ^user_id, order_by: [s.name, s.id])

    placements =
      Repo.all(
        from p in SectionPlacement,
          where: p.user_id == ^user_id,
          select: {p.project_id, p.section_id}
      )

    {sections, Map.new(placements)}
  end

  @doc "Create a personal section."
  @spec create(User.t(), map()) :: {:ok, Section.t()} | {:error, Ecto.Changeset.t()}
  def create(%User{id: user_id}, attrs) do
    %Section{user_id: user_id} |> Section.changeset(attrs) |> Repo.insert()
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

  @doc "Move an accessible project into a personal section, or out with an empty id."
  @spec move(User.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def move(%User{} = user, project_id, section_id) do
    with {:ok, _project} <- Projects.get(user, project_id) do
      place(user, project_id, section_id)
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

  defp place(%User{id: user_id}, project_id, "") do
    Repo.delete_all(
      from p in SectionPlacement, where: p.user_id == ^user_id and p.project_id == ^project_id
    )

    {:ok, nil}
  end

  defp place(%User{id: user_id} = user, project_id, section_id) do
    with {:ok, _section} <- fetch(user, section_id) do
      %SectionPlacement{user_id: user_id, project_id: project_id, section_id: section_id}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:section_id)
      |> Repo.insert(
        on_conflict: {:replace, [:section_id]},
        conflict_target: [:user_id, :project_id]
      )
    end
  end

  defp fetch(%User{id: user_id}, id) do
    case Repo.one(from s in Section, where: s.user_id == ^user_id and s.id == ^id) do
      nil -> {:error, :not_found}
      section -> {:ok, section}
    end
  end
end
