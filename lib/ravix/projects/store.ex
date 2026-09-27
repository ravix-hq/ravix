defmodule Ravix.Projects.Store do
  @moduledoc """
  The project rows, with nobody's permission established.

  Ids in, rows out. Nothing here asks who is calling, which is why it is its
  own module rather than a divider halfway down `Ravix.Projects`: a reader
  who lands on `get_project/1` should not have to scroll up to find out that
  it will hand a project to anybody who knows its id.

  `Ravix.Projects` is the module with the doors in it. This one is reached
  from there, from `Ravix.Accounts.Access` -- whose whole job is the read
  `live_project/1` makes -- and from the few contexts that hold a project id
  they were already let in to, each of which says so in a `# ownership:`
  comment that `Ravix.Credo.Architecture` insists on.
  """

  import Ecto.Query

  alias Ravix.Projects.Project
  alias Ravix.Repo
  alias Ravix.Tracks.Track

  @doc """
  A project that exists and has not been archived, or nil.

  Every door in `Ravix.Accounts.Access` starts here, and so does anything
  else that means "the project, if there is still a project": an archived
  one is gone for everybody, its owner included. It is one function rather
  than three copies of `Repo.get/2` and an `archived_at` check, because
  three copies is how one of them ends up admitting an archived project.
  """
  @spec live_project(String.t() | nil) :: Project.t() | nil
  def live_project(project_id) when is_binary(project_id) do
    case Repo.get(Project, project_id) do
      %Project{archived_at: nil} = project -> project
      _ -> nil
    end
  end

  def live_project(_), do: nil

  def lock_retirement(id),
    do: Repo.one!(from p in Project, where: p.id == ^id, lock: "FOR UPDATE")

  def set_retiring(id, retiring),
    do:
      Repo.update_all(from(p in Project, where: p.id == ^id),
        set: [shared_machine_retiring: retiring]
      )

  def finish_retirement(id, success?) do
    attrs =
      if success?,
        do: [shared_machine_retiring: false, shared_home_runtime: nil],
        else: [shared_machine_retiring: false]

    Repo.update_all(from(p in Project, where: p.id == ^id), set: attrs)
  end

  def secret_snapshots?(id) do
    # ownership: Access.project_access and owner checks admitted this secret change.
    Ravix.Config.dedicated_rollout?() or
      Repo.exists?(
        from t in Track,
          where: t.project_id == ^id and t.sandbox_layout == :dedicated and is_nil(t.closed_at)
      )
  end

  @doc "Invalidate snapshots before the provider mutation; concurrent writes serialize."
  def begin_secret_change(id) do
    # ownership: Access.project_access and owner checks in Settings admitted this secret change.
    Repo.transaction(fn ->
      project = Repo.one!(from p in Project, where: p.id == ^id, lock: "FOR UPDATE")
      if project.secrets_pending, do: Repo.rollback(:secrets_pending)
      generation = project.secrets_generation + 1

      Repo.update_all(from(p in Project, where: p.id == ^id),
        set: [secrets_generation: generation, secrets_pending: true]
      )

      # ownership: Access.project_access and owner checks admitted this project secret change.
      Repo.update_all(
        from(t in Track,
          where:
            t.project_id == ^id and
              t.sandbox_layout == :dedicated and is_nil(t.closed_at) and
              t.sandbox_state not in [:closing, :terminated]
        ),
        set: [
          setup_state: "failed",
          setup_error_code: "secrets_changed",
          setup_error: "Secrets changed — rebuild to apply",
          setup_lease: nil,
          setup_lease_until: nil
        ]
      )

      generation
    end)
  end

  def finish_secret_change(id, generation) do
    Repo.update_all(
      from(p in Project,
        where:
          p.id == ^id and
            p.secrets_generation == ^generation
      ),
      set: [secrets_pending: false]
    )

    :ok
  end

  @doc "Clear only the secret change the owner confirmed; snapshots remain invalidated."
  def confirm_secret_change(id, generation) do
    case Repo.update_all(
           from(p in Project,
             where: p.id == ^id and p.secrets_pending and p.secrets_generation == ^generation
           ),
           set: [secrets_pending: false],
           inc: [rev: 1]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :stale_secret_confirmation}
    end
  end

  @doc "Insert a project. `rev` starts at 1; `created_at` is stamped."
  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("rev", 1)
    %Project{} |> Project.changeset(attrs) |> Repo.insert()
  end

  @doc "One project by id, archived or not. Unscoped: callers establish ownership first."
  @spec get_project(String.t()) :: Project.t() | nil
  def get_project(id) when is_binary(id), do: Repo.get(Project, id)
  def get_project(_id), do: nil

  @doc """
  Several projects by id, archived or not, in no particular order.

  For a list that already holds the ids -- the rail, which has this person's
  track memberships in hand -- and would otherwise read them one at a time.
  Unscoped, as `get_project/1` is: the caller established how it came by
  each id. An id with no project behind it is simply absent.
  """
  @spec get_projects([String.t()]) :: [Project.t()]
  def get_projects([]), do: []
  def get_projects(ids) when is_list(ids), do: Repo.all(from(p in Project, where: p.id in ^ids))

  @doc "The live projects a person owns, oldest first."
  @spec projects_of(String.t()) :: [Project.t()]
  def projects_of(user_id) do
    Repo.all(
      from(p in Project,
        where: p.user_id == ^user_id and is_nil(p.archived_at),
        order_by: p.created_at
      )
    )
  end

  @doc "Rename a project. Unscoped: called beside a `project_of/2` that established ownership."
  @spec rename(String.t(), String.t()) :: :ok
  def rename(id, name), do: update_fields(id, name: name)

  @doc "Replace the person's extra instructions. Unscoped, as `rename/2`."
  @spec set_instructions(String.t(), String.t()) :: :ok
  def set_instructions(id, instructions), do: update_fields(id, instructions: instructions)

  @doc "Record the harness the agent now runs. Unscoped, as `rename/2`."
  @spec set_harness(String.t(), String.t(), String.t()) :: :ok
  def set_harness(id, runtime, model), do: update_fields(id, runtime: runtime, model: model)

  @doc """
  Bump the settings revision, and return the new one.

  Called whenever something Fountain injects at session start changes: a
  secret, an MCP server, a skill, the system prompt. Tracks already open
  carry the old number in their `channel_id` and are badged as running older
  settings, which is true and cannot be worked out any other way.
  """
  @spec bump_rev(String.t()) :: integer()
  def bump_rev(id) do
    query = from(p in Project, where: p.id == ^id, select: p.rev)

    case Repo.update_all(query, inc: [rev: 1]) do
      {1, [rev]} -> rev
      _ -> 1
    end
  end

  @doc """
  The one column of the three that ever moves, and only on a rebuild.

  Retiring the agent is what changes the sandbox identity; the environment
  and vault stay, which is what makes "new machine, same settings" a real
  distinction rather than a slower delete. Every track of the old disk is
  closed by the caller in the same breath: a track is a worktree, and that
  worktree is about to stop existing.

  `credential_set_id` is the set the *new* agent was built on, which moves
  with it for the reason `set_credential_set/2` exists at all.
  """
  @spec rebind_agent(String.t(), String.t(), String.t() | nil) :: :ok
  def rebind_agent(id, agent_id, credential_set_id),
    do:
      update_fields(id,
        agent_id: agent_id,
        credential_set_id: credential_set_id,
        runtime_agents_retiring: false,
        shared_home_runtime: nil
      )

  @doc """
  Record which of its owner's credential sets the project's agent now points
  at. Fountain is told first, by the caller; this is what lets the next wake
  see there is nothing to do. See `Ravix.Projects.Machine.adopt_credentials/2`.
  """
  @spec set_credential_set(String.t(), String.t()) :: :ok
  def set_credential_set(id, credential_set_id),
    do: update_fields(id, credential_set_id: credential_set_id)

  @doc "Archive a project, cancelling whatever its open tracks still had queued."
  @spec archive(String.t()) :: :ok
  def archive(id) do
    # ownership: `Ravix.Projects.destroy/2` admitted the owner through
    # `Access.project_of/2` before retiring this project. Archiving it takes
    # its tracks with it, and prompts queued for them have nowhere left to go.
    Enum.each(open_tracks(id), &Ravix.PromptQueue.Store.cancel_track(&1.id))
    update_fields(id, archived_at: DateTime.utc_now())
  end

  @doc """
  The open tracks of a project, oldest first, read here for the rebuild.

  The tracks context already answers this; asking it rather than writing the
  query again is what stops the two drifting about what "open" means.
  """
  # ownership: the rebuild and the archive both establish the project through
  # `Access.project_of/2` before naming its tracks.
  @spec open_tracks(String.t()) :: [Track.t()]
  defdelegate open_tracks(project_id), to: Ravix.Tracks.Store, as: :tracks_of

  def runtime_agents(project_id) do
    Repo.all(from(a in Ravix.Projects.RuntimeAgent, where: a.project_id == ^project_id))
  end

  def reserve_runtime(project_id, runtime, expected_agent \\ nil) do
    result =
      Repo.transaction(fn ->
        project = Repo.one(from(p in Project, where: p.id == ^project_id, lock: "FOR UPDATE"))

        if is_nil(project) or project.runtime_agents_retiring or not is_nil(project.archived_at) or
             (not is_nil(expected_agent) and project.agent_id != expected_agent),
           do: Repo.rollback(:retiring)

        {count, _} =
          Repo.insert_all(
            Ravix.Projects.RuntimeAgent,
            [%{project_id: project_id, runtime: runtime}],
            on_conflict: :nothing
          )

        if count == 1, do: :ok, else: Repo.rollback(:reserved)
      end)

    case result do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  def claim_shared_home(project_id, runtime, expected_agent) do
    Repo.transaction(fn ->
      project = Repo.one(from(p in Project, where: p.id == ^project_id, lock: "FOR UPDATE"))

      if is_nil(project) or project.runtime_agents_retiring or not is_nil(project.archived_at) or
           project.agent_id != expected_agent,
         do: Repo.rollback(:retiring)

      home = project.shared_home_runtime || runtime

      if is_nil(project.shared_home_runtime),
        do: update_fields(project_id, shared_home_runtime: home)

      home
    end)
  end

  def retire_runtimes(project_id), do: update_fields(project_id, runtime_agents_retiring: true)

  def bind_runtime(project_id, runtime, agent_id, credential_set_id) do
    from(a in Ravix.Projects.RuntimeAgent,
      where: a.project_id == ^project_id and a.runtime == ^runtime
    )
    |> Repo.update_all(set: [agent_id: agent_id, credential_set_id: credential_set_id])

    :ok
  end

  def forget_runtime(project_id, runtime) do
    from(a in Ravix.Projects.RuntimeAgent,
      where: a.project_id == ^project_id and a.runtime == ^runtime
    )
    |> Repo.delete_all()

    :ok
  end

  defp update_fields(id, fields) do
    from(p in Project, where: p.id == ^id) |> Repo.update_all(set: fields)
    :ok
  end
end
