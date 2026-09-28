defmodule Ravix.ThreadRuntimeTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Inference
  alias Ravix.Fountain
  alias Ravix.Fountain.{FakeTransport, Shapes}
  alias Ravix.Projects.RuntimeAgents
  alias Ravix.Tracks
  alias Ravix.Tracks.Store

  @models %{
    "claude" => [
      "anthropic/claude-fable-5-1",
      "anthropic/claude-opus-5-5",
      "anthropic/claude-opus-5",
      "anthropic/claude-sonnet-5"
    ],
    "codex" => ["openai/gpt-6-astra", "openai/gpt-5.6"]
  }

  setup do
    owner = insert_user(credential_set_id: "owner-set")
    project = insert_project(user: owner, runtime: "claude", credential_set_id: "owner-set")

    track =
      insert_track(project: project, conversation_id: "first", opened_at: DateTime.utc_now())

    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/conversations"}, {200, [], %{data: []}}}
        ],
        verify: false
      )

    stub(Fountain, :client, fn -> client end)

    stub(Ravix.MachineCache, :catalog, fn _ ->
      {:ok, %Shapes.Catalog{runtimes: ["claude", "codex"], models: @models}}
    end)

    stub(Fountain, :get_conversation, fn _, _ ->
      {:ok, Shapes.conversation(%{"id" => "first", "sandbox_id" => "disk"})}
    end)

    stub(Fountain, :sandbox, fn _, "disk" ->
      {:ok, Shapes.sandbox(%{"id" => "disk", "agent_id" => project.agent_id})}
    end)

    stub(Inference, :usable?, fn payer, _, [fresh: true] ->
      assert payer.id == owner.id
      {:ok, true}
    end)

    stub(Inference, :usable_agents, fn payer ->
      assert payer.id == owner.id
      {:ok, [:claude, :codex]}
    end)

    stub(Inference, :usable_agents, fn payer, [fresh: true] ->
      assert payer.id == owner.id
      {:ok, [:claude, :codex]}
    end)

    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)

    stub(Fountain, :create_conversation, fn _, launch ->
      {:ok,
       Shapes.conversation(%{"id" => Ecto.UUID.generate(), "sandbox_id" => launch.sandbox_id})}
    end)

    %{owner: owner, project: project, track: track, client: client}
  end

  test "a person's preference precedes track and project, but only when the payer can use it",
       ctx do
    alias Ravix.Accounts.ThreadPreference
    member = insert_user()
    stub(Ravix.MachineCache, :machine_for_track, fn _, _, _ -> {:ok, nil} end)
    insert_project_member(ctx.project, member)
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    catalog = %Shapes.Catalog{runtimes: ["claude", "codex"], models: @models}
    {:ok, _} = ThreadPreference.put(member, "codex", "openai/gpt-5.6", catalog)

    assert {:ok, %{runtime: "codex", model: "openai/gpt-5.6", source: :person}} =
             Tracks.thread_options(member, ctx.track.id)

    stub(Inference, :usable_agents, fn payer ->
      assert payer.id == ctx.owner.id
      {:ok, [:claude]}
    end)

    assert {:ok, %{runtime: "claude", source: :project}} =
             Tracks.thread_options(member, ctx.track.id)

    assert {:ok, _} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{
               runtime: "claude",
               preference_explicit: "true"
             })

    stub(Ravix.MachineCache, :machine_of, fn _, _ -> {:ok, nil} end)

    assert {:ok, %{runtime: "claude", source: :track}} =
             Tracks.thread_options(member, ctx.track.id)

    assert {:ok, %{runtime: "claude", source: :person}} =
             Tracks.thread_options(ctx.owner, ctx.track.id)

    outsider = insert_user()
    assert {:error, _} = Tracks.thread_options(outsider, ctx.track.id)
    assert {:error, _} = Tracks.add_thread(outsider, ctx.track.id, %{runtime: "claude"})
    assert {:ok, nil} = ThreadPreference.get(outsider, catalog)
  end

  test "new threads without an explicit runtime use the saved model", ctx do
    alias Ravix.Accounts.ThreadPreference
    catalog = %Shapes.Catalog{runtimes: ["claude", "codex"], models: @models}
    {:ok, _} = ThreadPreference.put(ctx.owner, "claude", "anthropic/claude-opus-5", catalog)
    assert {:ok, thread} = Tracks.add_thread(ctx.owner, ctx.track.id, %{})
    assert thread.runtime == "claude"
    assert thread.model == "anthropic/claude-opus-5"
    assert Store.thread(ctx.track.id).runtime == nil
  end

  test "without a preference the last runtime wins, and accepting a default does not pin it",
       ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    stub(Ravix.MachineCache, :machine_for_track, fn _, _, _ -> {:ok, nil} end)
    assert {:ok, %{source: :project}} = Tracks.thread_options(ctx.owner, ctx.track.id)

    {:ok, _} =
      Store.create_thread(%{
        track_id: ctx.track.id,
        title: "Previous",
        runtime: "claude",
        model: "anthropic/claude-sonnet-5"
      })

    assert {:ok, %{source: :track}} = Tracks.thread_options(ctx.owner, ctx.track.id)

    assert {:ok, _} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{
               "runtime" => "claude",
               "model" => "anthropic/claude-opus-5",
               "preference_explicit" => "false"
             })

    assert Ravix.Accounts.Store.get_user(ctx.owner.id).preferred_runtime == nil
  end

  for reason <- [:disconnected, :disabled] do
    test "without a preference, dialog and create skip a #{reason} remembered runtime", ctx do
      stub(Ravix.MachineCache, :machine_for_track, fn _, _, _ -> {:ok, nil} end)

      {:ok, _} =
        Store.create_thread(%{
          track_id: ctx.track.id,
          title: "Previous",
          runtime: "codex",
          model: "openai/gpt-6-astra"
        })

      if unquote(reason) == :disconnected do
        stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
        stub(Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)
        stub(Inference, :usable_agents, fn _, _ -> {:ok, [:claude]} end)
        stub(Inference, :usable?, fn _, runtime, _ -> {:ok, runtime == "claude"} end)
      end

      assert {:ok, %{runtime: "claude", source: :project, model: model}} =
               Tracks.thread_options(ctx.owner, ctx.track.id)

      assert {:ok, thread} = Tracks.add_thread(ctx.owner, ctx.track.id, %{})
      assert thread.runtime == "claude"
      assert thread.model == model
      assert Ravix.Accounts.Store.get_user(ctx.owner.id).preferred_runtime == nil
    end
  end

  test "home threads persist their model and leave legacy nullable threads readable", ctx do
    assert Store.thread(ctx.track.id).runtime == nil

    assert {:ok, thread} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{model: "anthropic/claude-opus-5"})

    assert thread.runtime == "claude"
    assert thread.model == "anthropic/claude-opus-5"
    assert Store.get_track(ctx.track.id).last_runtime == "claude"
    assert RuntimeAgents.ids(ctx.project) == [ctx.project.agent_id]
  end

  test "the server refuses a forged guest selection before creating an agent", ctx do
    reject(&Fountain.create_agent/2)
    reject(&Fountain.create_conversation/2)

    assert {:error,
            {:conflict, "guest_runtime_disabled",
             "Codex threads on this project aren't available yet."}} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})

    assert {:error, {:unprocessable, "invalid_runtime", "Choose Claude Code or Codex."}} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "unexpected"})
  end

  test "a member spends the owner's connection and cannot select a disconnected runtime", ctx do
    member = insert_user(credential_set_id: "member-set")
    insert_project_member(ctx.project, member)
    stub(Ravix.Config, :dedicated_opens_enabled?, fn user -> user.id == member.id end)

    stub(Inference, :usable?, fn payer, "codex", _ ->
      assert payer.id == ctx.owner.id
      {:ok, false}
    end)

    reject(&Fountain.create_agent/2)

    message = "#{ctx.owner.login} hasn't connected Codex."

    assert {:error, {:conflict, "agent_not_connected", ^message}} =
             Tracks.add_thread(member, ctx.track.id, %{runtime: "codex"})
  end

  for {home, guest} <- [{"claude", "codex"}, {"codex", "claude"}] do
    test "#{guest} joins #{home} using the same environment and vault", ctx do
      home = unquote(home)
      guest = unquote(guest)

      project =
        Repo.update!(Ecto.Changeset.change(ctx.project, runtime: home, model: hd(@models[home])))

      stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)

      expect(Fountain, :create_agent, fn _, body ->
        assert body.runtime == guest
        assert body.environment_id == project.environment_id
        assert body.vault_id == project.vault_id
        assert body.inference_credential_id == "owner-set"
        # A concurrent creator sees the durable reservation, never another POST.
        assert {:error, {:conflict, "runtime_agent_pending", _}} =
                 Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: guest})

        {:ok, %{"id" => "guest-agent"}}
      end)

      expect(Fountain, :create_conversation, 2, fn _, launch ->
        assert launch.agent_id == "guest-agent"
        assert launch.sandbox_id == "disk"
        assert launch.vault_id == project.vault_id
        assert launch.environment_id == project.environment_id

        assert launch.model ==
                 if(guest == "claude", do: "anthropic/claude-opus-5", else: "openai/gpt-6-astra")

        {:ok, Shapes.conversation(%{"id" => Ecto.UUID.generate(), "sandbox_id" => "disk"})}
      end)

      assert {:ok, first} = Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: guest})
      assert first.runtime == guest
      assert {:ok, next} = Tracks.add_thread(ctx.owner, ctx.track.id)
      assert next.runtime == guest
      assert Enum.sort(RuntimeAgents.ids(project)) == Enum.sort([project.agent_id, "guest-agent"])
    end
  end

  test "an uncertain agent create is never repeated", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    error = %Fountain.Error{status: 0, kind: :connection, message: "lost response"}
    expect(Fountain, :create_agent, fn _, _ -> {:error, error} end)
    assert {:error, ^error} = Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})

    assert {:error, {:conflict, "runtime_agent_pending", _}} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})

    assert {:error, {:conflict, "runtime_agent_pending", _}} =
             RuntimeAgents.retire(ctx.project, ctx.client)
  end

  test "a definite create refusal releases its reservation", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    error = %Fountain.Error{status: 422, kind: :api, message: "refused"}
    expect(Fountain, :create_agent, fn _, _ -> {:error, error} end)
    assert {:error, ^error} = Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})
    assert Ravix.Projects.Store.runtime_agents(ctx.project.id) == []
  end

  test "options disable guests outside the cohort and mark owner-disconnected runtimes", ctx do
    assert {:ok,
            %{
              runtimes: [
                %{runtime: "claude", connected: true, enabled: true},
                %{runtime: "codex", enabled: false}
              ]
            }} =
             Tracks.thread_options(ctx.owner, ctx.track.id)

    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    stub(Inference, :usable_agents, fn _ -> {:ok, [:claude]} end)

    assert {:ok, %{runtimes: [_, %{runtime: "codex", connected: false}]}} =
             Tracks.open_options(ctx.owner, ctx.project.id)

    assert {:error, :not_found} = Tracks.thread_options(insert_user(), ctx.track.id)
    assert {:error, :not_found} = Tracks.open_options(insert_user(), ctx.project.id)
  end

  test "the actual sandbox home remains available when it differs from the project default",
       ctx do
    :ok = Ravix.Projects.Store.reserve_runtime(ctx.project.id, "codex")
    :ok = Ravix.Projects.Store.bind_runtime(ctx.project.id, "codex", "codex-home", "owner-set")

    stub(Fountain, :sandbox, fn _, "disk" ->
      {:ok, Shapes.sandbox(%{"id" => "disk", "agent_id" => "codex-home"})}
    end)

    assert {:ok, %{runtime: "codex"}} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})

    assert {:error, {:conflict, "guest_runtime_disabled", _}} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "claude"})
  end

  test "retirement fences new runtime allocations until a replacement is bound", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    :ok = Ravix.Projects.Store.retire_runtimes(ctx.project.id)
    reject(&Fountain.create_agent/2)

    assert {:error, {:conflict, "runtime_agent_pending", _}} =
             Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})

    assert {:error, :retiring} =
             Ravix.Projects.Store.reserve_runtime(ctx.project.id, "codex", ctx.project.agent_id)

    :ok = Ravix.Projects.Store.rebind_agent(ctx.project.id, "new-home", "owner-set")

    assert {:error, :retiring} =
             Ravix.Projects.Store.reserve_runtime(ctx.project.id, "codex", ctx.project.agent_id)

    assert :ok = Ravix.Projects.Store.reserve_runtime(ctx.project.id, "codex", "new-home")
  end

  test "a catalog outage refuses a composer pick before changing the provider", ctx do
    stub(Ravix.MachineCache, :catalog, fn _ -> {:error, {:unavailable, "Catalog unavailable"}} end)

    reject(&Fountain.set_model/3)

    assert {:error, {:unavailable, "Catalog unavailable"}} =
             Tracks.set_model(ctx.owner, ctx.track.id, nil, ctx.project.model)

    assert Ravix.Accounts.Store.get_user(ctx.owner.id).preferred_model == nil
    stub(Ravix.MachineCache, :catalog, fn _ -> {:ok, Shapes.Catalog.empty()} end)

    assert {:error, {:unprocessable, "invalid_model", _}} =
             Tracks.set_model(ctx.owner, ctx.track.id, nil, ctx.project.model)
  end

  test "model updates persist on the selected runtime without changing siblings", ctx do
    {:ok, thread} =
      Store.create_thread(%{
        track_id: ctx.track.id,
        title: "Codex",
        conversation_id: "codex-conversation",
        runtime: "codex",
        model: "openai/gpt-6-astra"
      })

    expect(Fountain, :set_model, fn _, "codex-conversation", "openai/gpt-5.6" ->
      {:ok, Shapes.conversation(%{"id" => "codex-conversation", "model" => "openai/gpt-5.6"})}
    end)

    assert {:ok, "openai/gpt-5.6"} =
             Tracks.set_model(ctx.owner, ctx.track.id, thread.id, "openai/gpt-5.6")

    assert Store.get_thread(thread.id).model == "openai/gpt-5.6"
    assert Store.thread(ctx.track.id).model == nil

    assert {:error, {:unprocessable, "invalid_model", "Choose one of Codex's models."}} =
             Tracks.set_model(ctx.owner, ctx.track.id, thread.id, ctx.project.model)

    expect(Fountain, :events, fn _, "codex-conversation", _ -> {:ok, []} end)
    expect(Fountain, :turns, fn _, "codex-conversation" -> {:ok, []} end)

    assert {:ok, %{runtime: "codex"}} =
             Tracks.events(ctx.owner, ctx.track.id, thread_id: thread.id)
  end

  test "retiring a guest tolerates already gone and remembers failures for retry", ctx do
    :ok = Ravix.Projects.Store.reserve_runtime(ctx.project.id, "codex")
    :ok = Ravix.Projects.Store.bind_runtime(ctx.project.id, "codex", "guest", "owner-set")
    error = %Fountain.Error{status: 503, message: "unknown"}
    expect(Fountain, :delete_agent, fn _, "guest" -> {:error, error} end)
    assert {:error, ^error} = RuntimeAgents.retire(ctx.project, ctx.client)
    assert "guest" in RuntimeAgents.ids(ctx.project)
    expect(Fountain, :delete_agent, fn _, "guest" -> {:error, %Fountain.Error{status: 404}} end)
    assert :ok = RuntimeAgents.retire(ctx.project, ctx.client)
    assert RuntimeAgents.ids(ctx.project) == [ctx.project.agent_id]
  end

  test "a new private track gets its own machine and persists its first thread", ctx do
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    stub(Ravix.Projects, :prepare_machine, fn _, _ -> :ok end)

    expect(Fountain, :create_agent, fn _, %{runtime: "codex"} ->
      {:ok, %{"id" => "codex-home"}}
    end)

    assert {:ok, view} =
             Tracks.open(ctx.owner, ctx.project.id, %{
               title: "chosen-home",
               visibility: "private",
               runtime: "codex",
               model: "openai/gpt-5.6"
             })

    assert Store.thread(view.id).runtime == "codex"
    assert Store.thread(view.id).model == "openai/gpt-5.6"
    assert view.visibility == :private
    assert Store.get_track(view.id).visibility == :private
    assert Store.get_track(view.id).last_runtime == "codex"
    assert Store.get_track(view.id).sandbox_layout == :dedicated

    assert [%{resource_ids: %{"agent_id" => "codex-home"}, action: :open}] =
             Ravix.Tracks.Sandbox.Store.operations(view.id)

    assert Ravix.Projects.Store.get_project(ctx.project.id).shared_home_runtime == nil
    :ok = Ravix.Projects.Store.rebind_agent(ctx.project.id, "replacement", "owner-set")
    assert Ravix.Projects.Store.get_project(ctx.project.id).shared_home_runtime == nil
  end

  test "new threads adopt the owner's current credential set for either agent", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.owner, credential_set_id: "new-owner-set"))

    expect(Fountain, :update_agent, fn _, id, %{inference_credential_id: "new-owner-set"} ->
      assert id == ctx.project.agent_id
      {:ok, %{"id" => id}}
    end)

    assert {:ok, _} = Tracks.add_thread(ctx.owner, ctx.track.id)
    assert Ravix.Projects.Store.get_project(ctx.project.id).credential_set_id == "new-owner-set"
    :ok = Ravix.Projects.Store.reserve_runtime(ctx.project.id, "codex")
    :ok = Ravix.Projects.Store.bind_runtime(ctx.project.id, "codex", "guest", "owner-set")
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)

    expect(Fountain, :update_agent, fn _, "guest", %{inference_credential_id: "new-owner-set"} ->
      {:ok, %{"id" => "guest"}}
    end)

    assert {:ok, _} = Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})

    assert [%{credential_set_id: "new-owner-set"}] =
             Ravix.Projects.Store.runtime_agents(ctx.project.id)
  end

  test "dedicated thread attach and options use persisted ownership, never the shared machine",
       ctx do
    Repo.update!(Ecto.Changeset.change(ctx.project, repo_full_name: nil, installation_id: nil))

    Repo.update!(
      Ecto.Changeset.change(ctx.track,
        sandbox_layout: :dedicated,
        sandbox_state: :ready,
        sandbox_id: "track-disk",
        vault_id: "track-vault"
      )
    )

    :ok = Ravix.Projects.Store.reserve_runtime(ctx.project.id, "codex")
    :ok = Ravix.Projects.Store.bind_runtime(ctx.project.id, "codex", "guest", "owner-set")
    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    reject(&Fountain.get_conversation/2)
    reject(&Ravix.MachineCache.machine_of/2)

    expect(Fountain, :sandbox, 2, fn _, "track-disk" ->
      {:ok, Shapes.sandbox(%{"id" => "track-disk", "agent_id" => ctx.project.agent_id})}
    end)

    assert {:ok, _} = Tracks.thread_options(ctx.owner, ctx.track.id)

    expect(Fountain, :create_conversation, fn _, launch ->
      assert launch.agent_id == "guest"
      assert launch.sandbox_id == "track-disk"
      assert launch.vault_id == "track-vault"
      {:ok, Shapes.conversation(%{"id" => "dedicated-thread", "sandbox_id" => "track-disk"})}
    end)

    assert {:ok, _} = Tracks.add_thread(ctx.owner, ctx.track.id, %{runtime: "codex"})
    Repo.update!(Ecto.Changeset.change(Store.get_track(ctx.track.id), sandbox_id: nil))
    assert {:error, {:conflict, "not_open", _}} = Tracks.add_thread(ctx.owner, ctx.track.id)
  end
end
