defmodule Ravix.Workspaces.RaviSeed do
  @moduledoc """
  The one-time data step that sets up the "Ravi" team workspace (ADR 0009
  phase 4a, the owner's decisions of 2026-09-28).

    * The workspace is created with `jhgaylor` and `raunaksingwi` as its
      owners, found by GitHub login. Either missing refuses the whole step,
      as does either having been removed from Ravi, or demoted in it, since
      an earlier run. Nobody else is added.
    * The live `ravix-hq/*` projects either of them owns move into it
      (`projects.workspace_id`). Their legacy owner, members and track
      grants stay as they are, so every legacy door still admits whoever
      it did.
    * ravix2 (`d2fe4837-0e69-4a51-8201-e41d000fcb45`) is canonical for
      `ravix-hq/ravix` and uses the full repository name.
    * Raunak's `ravix` (`a7782c96-2407-4f0d-a62f-4c2215039d6f`) is marked
      its legacy duplicate through
      `Ravix.Workspaces.Store.mark_legacy_duplicate/3` with an explicit
      canonical choice, because the owner chose the later project over
      "first created wins". It keeps its open tracks and members, and moves
      in with the rest; the index that keeps one project per repository per
      workspace does not count a marked duplicate.

  Two further projects of one repository, which nobody has decided about,
  are reported and left where they are.

  A dry run by default: `run(apply: false)` works out and returns the plan
  and writes nothing. `run(apply: true)` writes it in one transaction.
  Running it again finds everything done and changes nothing. The summary
  holds ids, names, logins and repositories, and no secret.

  An operator step, run as no user: there is no door to go through, which
  is why every row it touches goes through `Ravix.Workspaces.Store`.
  """

  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Workspaces.{Store, Workspace}

  @name "Ravi"
  @owners ["jhgaylor", "raunaksingwi"]
  @org "ravix-hq"
  @canonical "d2fe4837-0e69-4a51-8201-e41d000fcb45"
  @canonical_name "ravix-hq/ravix"
  @duplicate "a7782c96-2407-4f0d-a62f-4c2215039d6f"

  @type action :: :move | :in_place | :conflict | :elsewhere
  @type project_line :: %{
          id: String.t(),
          name: String.t(),
          repo: String.t() | nil,
          action: action(),
          rename: String.t() | nil,
          duplicate_of: String.t() | nil
        }
  @type summary :: %{
          applied: boolean(),
          workspace: %{id: String.t() | nil, name: String.t(), create: boolean()},
          owners: [String.t()],
          projects: [project_line()]
        }

  @doc "Work out the seed, and write it when `apply: true`."
  @spec run(keyword()) ::
          {:ok, summary()}
          | {:error,
             {:missing_owner, String.t()}
             | {:missing_project, String.t()}
             | {:not_canonical_repo, String.t()}
             | {:revoked_owner, String.t()}
             | {:not_owner, String.t()}
             | :ambiguous_workspace
             | {:mark, atom()}}
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)

    with {:ok, owners} <- owners(),
         {:ok, workspace} <- existing_workspace(owners),
         {:ok, lines} <- plan(owners, workspace) do
      summary = %{
        applied: false,
        workspace: %{id: workspace && workspace.id, name: @name, create: is_nil(workspace)},
        owners: Enum.map(owners, & &1.login),
        projects: lines
      }

      if apply?, do: write(summary, owners, workspace), else: {:ok, summary}
    end
  end

  defp owners do
    Enum.reduce_while(@owners, {:ok, []}, fn login, {:ok, acc} ->
      # ownership: no door -- the operator data step; the login names an owner.
      case Ravix.Accounts.Store.user_by_login(login) do
        nil -> {:halt, {:error, {:missing_owner, login}}}
        user -> {:cont, {:ok, acc ++ [user]}}
      end
    end)
  end

  defp existing_workspace(owners) do
    case Store.team_workspaces_named(@name, Enum.map(owners, & &1.id)) do
      [] -> {:ok, nil}
      [workspace] -> owners_standing(workspace, owners)
      _several -> {:error, :ambiguous_workspace}
    end
  end

  # An owner removed from Ravi is not quietly re-added, nor reported as an
  # owner: the step refuses and says who, and somebody decides.
  defp owners_standing(workspace, owners) do
    Enum.reduce_while(owners, {:ok, workspace}, fn owner, ok ->
      case Store.membership_row(workspace.id, owner.id) do
        %{revoked_at: %DateTime{}} -> {:halt, {:error, {:revoked_owner, owner.login}}}
        %{role: role} when role != :owner -> {:halt, {:error, {:not_owner, owner.login}}}
        _live_owner_or_none -> {:cont, ok}
      end
    end)
  end

  defp plan(owners, workspace) do
    projects = Store.seed_projects(Enum.map(owners, & &1.id), @org, [@canonical, @duplicate])
    canonical = Enum.find(projects, &(&1.id == @canonical))
    duplicate = Enum.find(projects, &(&1.id == @duplicate))

    with :ok <- present(canonical, @canonical),
         :ok <- present(duplicate, @duplicate),
         :ok <- canonical_repo(canonical),
         :ok <- canonical_repo(duplicate) do
      {:ok, lines(projects, workspace)}
    end
  end

  defp present(nil, id), do: {:error, {:missing_project, id}}
  defp present(%Project{}, _id), do: :ok

  defp canonical_repo(%Project{} = project) do
    if Project.normalize_repo(project.repo_full_name) == "#{@org}/ravix",
      do: :ok,
      else: {:error, {:not_canonical_repo, project.id}}
  end

  # Repositories with more than one undecided project are left alone: the
  # owners decided ravix-hq/ravix, and nothing else.
  defp lines(projects, workspace) do
    undecided =
      projects
      |> Enum.reject(&(&1.id == @duplicate or not is_nil(&1.legacy_duplicate_at)))
      |> Enum.frequencies_by(&Project.normalize_repo(&1.repo_full_name))

    Enum.map(projects, fn project ->
      repo = Project.normalize_repo(project.repo_full_name)

      %{
        id: project.id,
        name: project.name,
        repo: project.repo_full_name,
        action: action(project, workspace, Map.get(undecided, repo, 0)),
        rename:
          if(project.id == @canonical and project.name != @canonical_name,
            do: @canonical_name
          ),
        duplicate_of: if(project.id == @duplicate, do: @canonical)
      }
    end)
  end

  defp action(%Project{workspace_id: nil, id: id}, _workspace, _count)
       when id in [@canonical, @duplicate],
       do: :move

  defp action(%Project{workspace_id: nil}, _workspace, count) when count > 1, do: :conflict
  defp action(%Project{workspace_id: nil}, _workspace, _count), do: :move
  defp action(%Project{workspace_id: id}, %Workspace{id: id}, _count), do: :in_place
  defp action(%Project{}, _workspace, _count), do: :elsewhere

  defp write(summary, owners, workspace) do
    # ownership: no door -- the operator data step; every row below is
    # written through `Ravix.Workspaces.Store`, in one transaction.
    Repo.transaction(fn ->
      workspace = workspace || create!(hd(owners))
      Enum.each(owners, &Store.ensure_owner(workspace.id, &1.id))

      # The duplicate is marked while still outside the workspace, so the
      # one-project-per-repository index never sees two live entries.
      case Store.mark_legacy_duplicate(@duplicate, @canonical, canonical: :explicit) do
        {:ok, _marked} -> :ok
        {:error, reason} -> Repo.rollback({:mark, reason})
      end

      for %{action: :move, id: id} <- summary.projects, do: Store.move_project(id, workspace.id)

      for %{rename: name, id: id} when is_binary(name) <- summary.projects,
          do: Store.rename_project(id, name)

      %{
        summary
        | applied: true,
          workspace: %{summary.workspace | id: workspace.id}
      }
    end)
  end

  defp create!(owner) do
    case Store.create_team_workspace(owner.id, @name) do
      {:ok, workspace} -> workspace
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "The summary as lines of text, for the task's output. No secrets."
  @spec format(summary()) :: [String.t()]
  def format(summary) do
    mode = if summary.applied, do: "Applied", else: "Dry run (pass --apply to write)"
    ws = summary.workspace

    [
      "#{mode}: team workspace \"#{ws.name}\" " <>
        if(ws.create and not summary.applied, do: "(to be created)", else: "(#{ws.id})"),
      "Owners: " <> Enum.map_join(summary.owners, ", ", &("@" <> &1))
    ] ++
      Enum.map(summary.projects, fn line ->
        extra =
          [
            line.rename && "rename to \"#{line.rename}\"",
            line.duplicate_of && "legacy duplicate of #{line.duplicate_of} (explicit canonical)"
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("", &("; " <> &1))

        "  #{line.id} #{line.name} (#{line.repo || "no repository"}): " <>
          describe(line.action) <> extra
      end)
  end

  @doc "Why the seed refused, as a sentence."
  @spec describe_error(term()) :: String.t()
  def describe_error({:missing_owner, login}),
    do: "@#{login} has not signed in to Ravix, so cannot be an owner."

  def describe_error({:revoked_owner, login}),
    do:
      "@#{login} was removed from #{@name}. Re-add them there by hand, or leave them out " <>
        "deliberately; the seed will not do either."

  def describe_error({:not_owner, login}),
    do: "@#{login} is in #{@name} but not as an owner. Make them an owner there first."

  def describe_error({:missing_project, id}), do: "project #{id} does not exist."

  def describe_error({:not_canonical_repo, id}),
    do: "project #{id} is not a project of #{@org}/ravix."

  def describe_error(:ambiguous_workspace),
    do: "more than one \"#{@name}\" team workspace exists; resolve that by hand."

  def describe_error({:mark, reason}), do: "marking the duplicate failed: #{reason}."
  def describe_error(%Ecto.Changeset{}), do: "the workspace could not be created."

  defp describe(:move), do: "move into the workspace"
  defp describe(:in_place), do: "already in the workspace"
  defp describe(:conflict), do: "left alone: another undecided project has this repository"
  defp describe(:elsewhere), do: "left alone: already in another workspace"
end
