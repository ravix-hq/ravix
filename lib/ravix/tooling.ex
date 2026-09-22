defmodule Ravix.Tooling do
  @moduledoc "Scoped operations shared by MCP and A2A. External output is explicitly selected."
  alias Ravix.Accounts.Access
  alias Ravix.{Config, Fountain, Projects, Tracks}
  alias Ravix.Tooling.{Catalog, OAuth, Receipt, Store, Tasks}

  def call(principal, name, args) do
    with %{} = tool <- Catalog.find(name),
         true <- Catalog.validate(args, tool.inputSchema),
         {:ok, principal} <- OAuth.check(principal, tool.scope),
         {:ok, result} <- execute(principal, name, args),
         {:ok, principal} <- OAuth.check(principal, tool.scope),
         :ok <- recheck(principal, name, args, result) do
      {:ok, result}
    else
      nil ->
        {:error, {:unprocessable, "unknown_tool", "Unknown tool."}}

      false ->
        {:error,
         {:unprocessable, "invalid_arguments", "Arguments do not match this tool's schema."}}

      error ->
        error
    end
  end

  defp execute(p, "list_projects", a),
    do: {:ok, page(Enum.map(Projects.list(p.user), &project/1), a)}

  defp execute(p, "list_repositories", a),
    do: map_result(Projects.repos(p.user, a["installation_id"]), &public_repos(&1, a))

  defp execute(p, "list_tracks", a),
    do:
      map_result(
        Tracks.list(p.user, a["project_id"]),
        &page(Enum.map(&1, fn v -> track(v) end), a)
      )

  defp execute(p, "get_track", a),
    do: map_result(Tracks.get(p.user, a["track_id"]), &track(&1.track))

  defp execute(p, "get_project_settings", a),
    do: map_result(Projects.settings(p.user, a["project_id"]), &settings/1)

  defp execute(p, "read_track", a), do: events(p, a)

  defp execute(p, "send_prompt", a),
    do:
      map_result(
        Tasks.send(p, a["track_id"], a["prompt"], a["request_id"], a["thread_id"]),
        &Tasks.present/1
      )

  defp execute(p, "get_task", a), do: map_result(Tasks.get(p, a["task_id"]), &Tasks.present/1)

  defp execute(p, "cancel_task", a),
    do: map_result(Tasks.cancel(p, a["task_id"]), &Tasks.present/1)

  defp execute(p, name, a) do
    with :ok <- mutation_access(p, name, a) do
      receipt(p, name, a, fn -> mutate(p, name, a) end)
    end
  end

  defp mutation_access(_p, "create_project", _), do: :ok

  defp mutation_access(p, "create_track", a),
    do: access_result(Access.project_access(p.user, a["project_id"]))

  defp mutation_access(p, "update_project_settings", a),
    do: access_result(Access.project_of(p.user, a["project_id"]))

  defp access_result({:ok, _}), do: :ok
  defp access_result(error), do: error

  defp mutate(p, "create_project", a),
    do: map_result(Projects.create(p.user, Map.drop(a, ["request_id"])), &project/1)

  defp mutate(p, "create_track", a),
    do:
      map_result(
        Tracks.open(p.user, a["project_id"], Map.drop(a, ["project_id", "request_id"])),
        &track/1
      )

  defp mutate(p, "update_project_settings", a) do
    case Projects.update_settings(p.user, a["project_id"], a["settings"]) do
      {:ok, _} -> {:ok, %{updated: true}}
      error -> error
    end
  end

  # A committed claim precedes external side effects. If the process dies after
  # provider acceptance, retries report uncertainty rather than provisioning twice.
  defp receipt(p, name, args, fun) do
    id = Tasks.digest({p.user.id, p.grant.client_id, name, args["request_id"]})
    fingerprint = Tasks.digest(args)

    row = %Receipt{
      id: id,
      user_id: p.user.id,
      client_id: p.grant.client_id,
      operation: name,
      fingerprint: fingerprint
    }

    case Store.claim_receipt(row) do
      {:new, saved} ->
        case fun.() do
          {:ok, result} ->
            Store.update(saved, result: json_map(result))
            {:ok, result}

          error ->
            error
        end

      {:existing, %Receipt{fingerprint: ^fingerprint, result: result}} when is_map(result) ->
        {:ok, result}

      {:existing, %Receipt{fingerprint: ^fingerprint}} ->
        {:error,
         {:conflict, "operation_unconfirmed",
          "This operation is in progress or its outcome is unconfirmed. Inspect the project before retrying with a new ID."}}

      _ ->
        {:error, {:conflict, "request_id_used", "This request ID already names different work."}}
    end
  end

  defp events(p, args) do
    with {:ok, %{track: track, thread: thread}} <-
           Access.thread_access(p.user, args["track_id"], args["thread_id"]),
         {:ok, client} <- Ravix.Providers.fountain(),
         {:ok, page} <-
           Fountain.events_page(client, thread.conversation_id,
             after: args["after"],
             limit: Map.get(args, "limit", 50)
           ),
         {:ok, _} <- OAuth.check(p, "tracks:read"),
         {:ok, _} <- Access.track_access(p.user, track.id) do
      {:ok,
       %{
         events: Enum.map(page.events, &public_event/1),
         next_cursor: page.next_cursor,
         has_more: page.has_more
       }}
    end
  end

  defp page(items, args) do
    limit = Map.get(args, "limit", 50)

    rows =
      items
      |> Enum.sort_by(&page_key/1)
      |> Enum.filter(&(page_key(&1) > Map.get(args, "after", "")))

    selected = Enum.take(rows, limit)
    %{items: selected, next_cursor: if(length(rows) > limit, do: page_key(List.last(selected)))}
  end

  defp page_key(item), do: item[:id] || item[:full_name]

  defp public_event(event) do
    public = Map.take(event, ~w(id turn_id kind stage state stream data ts))

    case public["data"] do
      data when is_binary(data) and byte_size(data) > 16_000 ->
        public |> Map.put("data", String.slice(data, 0, 4_000)) |> Map.put("truncated", true)

      _ ->
        public
    end
  end

  defp recheck(p, "list_projects", _, result),
    do: all_access(result.items, &Projects.get(p.user, &1.id))

  defp recheck(p, "list_tracks", _, result),
    do: all_access(result.items, &Access.track_access(p.user, &1.id))

  defp recheck(p, name, args, _) when name in ["get_track", "read_track", "send_prompt"],
    do: access_result(Access.track_access(p.user, args["track_id"]))

  defp recheck(p, name, args, _) when name in ["get_project_settings", "update_project_settings"],
    do: access_result(Access.project_of(p.user, args["project_id"]))

  defp recheck(p, "create_track", _, result),
    do: access_result(Access.track_access(p.user, result[:id] || result["id"]))

  defp recheck(p, "create_project", _, result),
    do: access_result(Access.project_of(p.user, result[:id] || result["id"]))

  defp recheck(_, _, _, _), do: :ok

  defp all_access(items, check) do
    if Enum.all?(items, &match?({:ok, _}, check.(&1))), do: :ok, else: {:error, :not_found}
  end

  defp project(v),
    do:
      Map.take(v, [:id, :name, :repo, :default_branch, :runtime, :model, :role, :access])
      |> Map.put(:url, Config.public_url() <> "/p/" <> v.id)

  defp track(v),
    do:
      Map.take(v, [
        :id,
        :project_id,
        :title,
        :branch,
        :workdir,
        :status,
        :created_by_login
      ])
      # Fountain's conversation ids stay on this side, as they do for the track.
      |> Map.put(:threads, Enum.map(v.threads, &Map.take(&1, [:id, :title, :default, :status])))
      |> Map.put(:url, Config.public_url() <> "/p/#{v.project_id}/t/#{v.id}")

  defp settings(v),
    do:
      Map.take(v, [
        :name,
        :runtime,
        :model,
        :instructions,
        :setup_script,
        :packages,
        :env_keys,
        :vault_keys
      ])

  defp public_repos(value, args) do
    %{
      selected: value.selected,
      installations: Enum.map(value.installations, &Map.take(&1, [:id, :login, :account])),
      repositories:
        page(
          Enum.map(
            value.repos,
            &Map.take(&1, [:full_name, :name, :private, :default_branch, :installation_id])
          ),
          args
        )
    }
  end

  defp map_result({:ok, value}, fun), do: {:ok, fun.(value)}
  defp map_result(error, _), do: error
  defp json_map(value), do: value |> Jason.encode!() |> Jason.decode!()
end
