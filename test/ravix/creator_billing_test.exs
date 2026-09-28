defmodule Ravix.CreatorBillingTest do
  @moduledoc """
  ADR 0009 phase 6 behind `RAVIX_CREATOR_BILLING` (`docs/creator-billing.md`).

  Not async: the switch is application configuration, read at call time, and
  these tests flip it. Every Fountain answer is scripted in Fountain's own
  JSON through `FakeTransport`, and every creator-billed create asserts the
  `inference_credential_id` it sent, because a create that names nothing
  runs on the project owner's set.
  """
  use Ravix.DataCase, async: false
  use Mimic
  require Logger

  alias Ravix.Accounts.Inference
  alias Ravix.Fountain
  alias Ravix.Fountain.{Error, FakeTransport, Launch, Shapes}
  alias Ravix.Projects
  alias Ravix.Projects.RuntimeAgents
  alias Ravix.PromptQueue.Server, as: QueueServer
  alias Ravix.Schedules
  alias Ravix.Tooling
  alias Ravix.Tracks
  alias Ravix.Tracks.{Billing, Track}

  setup :verify_on_exit!

  @models %{
    "claude" => ["anthropic/claude-opus-5-5"],
    "codex" => ["openai/gpt-6-astra"]
  }

  setup do
    previous = Application.get_env(:ravix, :creator_billing)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ravix, :creator_billing),
        else: Application.put_env(:ravix, :creator_billing, previous)
    end)

    owner = insert_user(credential_set_id: "owner-set")
    creator = insert_user(credential_set_id: "creator-set")
    collab = insert_user(credential_set_id: "collab-set")

    project =
      insert_project(
        user: owner,
        runtime: "claude",
        model: "anthropic/claude-opus-5-5",
        credential_set_id: "owner-set",
        repo_full_name: nil,
        installation_id: nil
      )

    insert_project_member(project, creator)
    insert_project_member(project, collab)

    stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> true end)
    stub(Ravix.Config, :threads_enabled?, fn -> true end)

    stub(Ravix.MachineCache, :catalog, fn _ ->
      {:ok, %Shapes.Catalog{runtimes: ["claude", "codex"], models: @models}}
    end)

    %{owner: owner, creator: creator, collab: collab, project: project}
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp switch(on), do: Application.put_env(:ravix, :creator_billing, on)

  # Who has connected what, by user id. Every usability read in the code goes
  # through one of these three, so a payer's identity is visible in each.
  defp connections(map) do
    usable = fn user -> Map.get(map, user.id, []) end

    stub(Inference, :usable_agents, fn user -> {:ok, usable.(user)} end)
    stub(Inference, :usable_agents, fn user, _opts -> {:ok, usable.(user)} end)

    stub(Inference, :usable?, fn user, agent, _opts ->
      {:ok, Enum.any?(usable.(user), &(to_string(&1) == to_string(agent)))}
    end)
  end

  defp fountain(expectations, opts \\ []) do
    client = FakeTransport.client(expectations, opts)
    stub(Fountain, :client, fn -> client end)
    client
  end

  defp agent(id, default, allowed),
    do:
      {200, [],
       %{
         data: %{
           id: id,
           runtime: "claude",
           inference_credential_id: default,
           allowed_inference_credential_ids: allowed,
           inference_credential_access:
             if(is_nil(allowed), do: "all_tenant_credential_sets", else: "allowlist")
         }
       }}

  # No provider-named value anywhere: the environment's readable variables,
  # its secrets, and a vault's secrets, as Fountain lists them.
  defp clean(environment_id, vault_id) do
    [
      {%{method: "GET", path: "/api/environments/#{environment_id}"},
       {200, [], %{data: %{id: environment_id, env_vars: %{"MIX_ENV" => "dev"}}}}},
      {%{method: "GET", path: "/api/environments/#{environment_id}/secrets"},
       {200, [], %{data: [%{key: "GITHUB_TOKEN", updated_at: "2026-09-28T00:00:00Z"}]}}},
      {%{method: "GET", path: "/api/vaults/#{vault_id}/secrets"}, {200, [], %{data: []}}}
    ]
  end

  defp creator_billed(track),
    do: track |> Ecto.Changeset.change() |> Track.creator_billing_changeset() |> Repo.update!()

  defp ready_track(ctx, attrs \\ []) do
    insert_track(
      Keyword.merge(
        [
          project: ctx.project,
          sandbox_layout: :dedicated,
          sandbox_state: :ready,
          sandbox_id: "disk-#{System.unique_integer([:positive])}",
          vault_id: "track-vault",
          conversation_id: "c-#{System.unique_integer([:positive])}",
          created_by: ctx.creator.id,
          created_by_login: ctx.creator.login,
          opened_at: DateTime.utc_now()
        ],
        attrs
      )
    )
  end

  defp request_id, do: Ecto.UUID.generate()

  defp start_thread(user, track, runtime) do
    Tracks.start_thread(user, track.id, %{runtime: runtime}, %{
      prompt: "work",
      request_id: request_id()
    })
  end

  defp created(client) do
    client
    |> FakeTransport.calls()
    |> Enum.filter(&(&1.method == "POST" and &1.path == "/api/conversations"))
    |> Enum.map(& &1.body)
  end

  # ── the switch ────────────────────────────────────────────────────────

  test "the switch is off unless configured exactly true" do
    Application.delete_env(:ravix, :creator_billing)
    refute Ravix.Config.creator_billing?()
    switch("true")
    refute Ravix.Config.creator_billing?()
    switch(true)
    assert Ravix.Config.creator_billing?()
  end

  # ── opening ───────────────────────────────────────────────────────────

  describe "opening a dedicated track" do
    test "with the switch on the creator pays: their harnesses, their set admitted, their row",
         ctx do
      switch(true)
      connections(%{ctx.creator.id => [:claude], ctx.owner.id => [:claude, :codex]})
      agent_id = ctx.project.agent_id

      client =
        fountain(
          clean(ctx.project.environment_id, ctx.project.vault_id) ++
            [
              {%{method: "GET", path: "/api/agents/#{agent_id}"},
               agent(agent_id, "owner-set", [])},
              {%{
                 method: "PUT",
                 path: "/api/agents/#{agent_id}",
                 body: %{allowed_inference_credential_ids: ["creator-set"]}
               }, agent(agent_id, "owner-set", ["creator-set"])},
              {%{method: "GET", path: "/api/agents/#{agent_id}"},
               agent(agent_id, "owner-set", ["creator-set"])}
            ]
        )

      assert {:ok, view} = Tracks.open(ctx.creator, ctx.project.id, %{"runtime" => "claude"})
      track = Tracks.Store.get_track(view.id)
      assert track.billing_policy == :creator
      assert track.payer_user_id == ctx.creator.id
      assert Track.payer(track, ctx.project) == {:creator, ctx.creator.id}
      assert view.billing == :creator
      assert view.payer_login == ctx.creator.login
      assert FakeTransport.calls(client) |> Enum.count() == 6
    end

    test "with the switch off nothing changes: the owner pays and no agent is touched", ctx do
      switch(false)
      connections(%{ctx.owner.id => [:claude]})
      client = fountain([])

      assert {:ok, view} = Tracks.open(ctx.creator, ctx.project.id, %{"runtime" => "claude"})
      track = Tracks.Store.get_track(view.id)
      assert is_nil(track.billing_policy)
      assert is_nil(track.payer_user_id)
      assert Track.payer(track, ctx.project) == {:legacy_owner, ctx.owner.id}
      assert FakeTransport.calls(client) == []
    end

    test "a creator with no usable harness is sent to connect one, and nothing is opened", ctx do
      switch(true)
      connections(%{ctx.owner.id => [:claude, :codex]})
      fountain([])

      assert {:error,
              {:conflict, "creator_not_connected",
               "Connect Claude or Codex to start a track — you pay for its agent."}} =
               Tracks.open(ctx.creator, ctx.project.id, %{"runtime" => "claude"})

      assert Tracks.Store.tracks_of(ctx.project.id) == []

      nobody = insert_user()
      insert_project_member(ctx.project, nobody)

      assert {:error, {:conflict, "creator_not_connected", _}} =
               Tracks.open(nobody, ctx.project.id, %{})
    end

    test "a harness only the owner connected is refused, never lent", ctx do
      switch(true)
      connections(%{ctx.creator.id => [:claude], ctx.owner.id => [:claude, :codex]})
      fountain(clean(ctx.project.environment_id, ctx.project.vault_id))

      assert {:error, {:conflict, "agent_not_connected", message}} =
               Tracks.open(ctx.creator, ctx.project.id, %{"runtime" => "codex"})

      assert message =~ ctx.creator.login
      assert Tracks.Store.tracks_of(ctx.project.id) == []
    end

    test "MCP create_track goes through the same refusal", ctx do
      switch(true)
      connections(%{ctx.owner.id => [:claude]})
      fountain([])
      {principal, _, _} = Ravix.ToolingFixture.principal(ctx.creator)

      assert {:error, {:conflict, "creator_not_connected", _}} =
               Tooling.call(principal, "create_track", %{
                 "project_id" => ctx.project.id,
                 "request_id" => "creator-billing-mcp"
               })

      assert Tracks.Store.tracks_of(ctx.project.id) == []
    end

    test "a provider-named project secret is refused by name, before anything is opened", ctx do
      switch(true)
      connections(%{ctx.creator.id => [:claude]})
      env = ctx.project.environment_id

      fountain([
        {%{method: "GET", path: "/api/environments/#{env}"},
         {200, [], %{data: %{id: env, env_vars: %{"MIX_ENV" => "dev"}}}}},
        {%{method: "GET", path: "/api/environments/#{env}/secrets"},
         {200, [], %{data: [%{key: "ANTHROPIC_API_KEY", updated_at: "2026-09-28T00:00:00Z"}]}}},
        {%{method: "GET", path: "/api/vaults/#{ctx.project.vault_id}/secrets"},
         {200, [], %{data: [%{key: "OPENAI_API_KEY"}]}}}
      ])

      assert {:error, {:conflict, "provider_secret", message}} =
               Tracks.open(ctx.creator, ctx.project.id, %{"runtime" => "claude"})

      assert message =~ "ANTHROPIC_API_KEY, OPENAI_API_KEY"
      assert Tracks.Store.tracks_of(ctx.project.id) == []
    end

    test "the opening conversation names the creator's set", ctx do
      track = creator_billed(ready_track(ctx, conversation_id: nil, sandbox_id: nil))
      {:ok, op} = Tracks.Sandbox.Store.begin_operation(track.id, track.sandbox_generation, :open)

      {:ok, op} =
        Tracks.Sandbox.Store.update_operation(op, %{
          phase: "vault_ready",
          resource_ids: %{
            "agent_id" => ctx.project.agent_id,
            "environment_id" => ctx.project.environment_id,
            "vault_id" => "track-vault",
            "source_vault_id" => ctx.project.vault_id,
            "runtime" => "claude",
            "model" => "anthropic/claude-opus-5-5",
            "channel_id" => "open-channel"
          }
        })

      agent_id = ctx.project.agent_id

      client =
        FakeTransport.client(
          clean(ctx.project.environment_id, "track-vault") ++
            [
              {%{method: "GET", path: "/api/agents/#{agent_id}"},
               agent(agent_id, "owner-set", ["creator-set"])},
              {%{method: "POST", path: "/api/conversations"},
               {201, [], %{data: %{id: "opened", sandbox_id: "fresh-disk"}}}}
            ],
          verify: false
        )

      Tracks.Sandbox.advance(client, op.id)
      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
    end

    test "a refused creator credential at open fails setup naming the creator", ctx do
      track = creator_billed(ready_track(ctx, conversation_id: nil, sandbox_id: nil))
      {:ok, op} = Tracks.Sandbox.Store.begin_operation(track.id, track.sandbox_generation, :open)

      {:ok, op} =
        Tracks.Sandbox.Store.update_operation(op, %{
          phase: "vault_ready",
          resource_ids: %{
            "agent_id" => ctx.project.agent_id,
            "environment_id" => ctx.project.environment_id,
            "vault_id" => "track-vault",
            "source_vault_id" => ctx.project.vault_id,
            "runtime" => "claude",
            "channel_id" => "open-channel"
          }
        })

      agent_id = ctx.project.agent_id

      client =
        FakeTransport.client(
          clean(ctx.project.environment_id, "track-vault") ++
            [
              {%{method: "GET", path: "/api/agents/#{agent_id}"},
               agent(agent_id, "owner-set", ["creator-set"])},
              {%{method: "POST", path: "/api/conversations"},
               {422, [],
                %{
                  error: "inference_credential_unusable",
                  message: "the selected credential set has no credential this runtime can use"
                }}}
            ],
          verify: false
        )

      Tracks.Sandbox.advance(client, op.id)
      failed = Tracks.Store.get_track(track.id)
      assert failed.setup_error == "Paused: @#{ctx.creator.login} hasn't connected Claude Code."
      assert %{"claude" => %{"code" => "inference_credential_unusable"}} = failed.billing_pauses
      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
    end
  end

  # ── threads ───────────────────────────────────────────────────────────

  describe "threads on a creator-billed track" do
    setup ctx do
      track = creator_billed(ready_track(ctx))
      %{track: track}
    end

    defp thread_fountain(ctx, creates) do
      agent_id = ctx.project.agent_id
      admitted = agent(agent_id, "owner-set", ["creator-set"])

      per_create =
        [{%{method: "GET", path: "/api/agents/#{agent_id}"}, admitted}] ++
          clean(ctx.project.environment_id, "track-vault") ++
          [
            {%{method: "POST", path: "/api/conversations"},
             fn _call ->
               {201, [], %{data: %{id: Ecto.UUID.generate(), sandbox_id: "disk"}}}
             end}
          ]

      FakeTransport.client(List.flatten(List.duplicate(per_create, creates)))
      |> tap(fn client -> stub(Fountain, :client, fn -> client end) end)
    end

    test "every member's thread runs on the creator's set, whoever starts it", ctx do
      switch(false)
      connections(%{ctx.creator.id => [:claude], ctx.owner.id => [:claude, :codex]})
      client = thread_fountain(ctx, 2)
      test = self()

      tasks =
        for user <- [ctx.collab, ctx.owner] do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())
            start_thread(user, ctx.track, "claude")
          end)
        end

      threads = Enum.map(tasks, &Task.await(&1, 15_000))
      assert Enum.all?(threads, &match?({:ok, %Tracks.Thread{runtime: "claude"}}, &1))
      assert [_, _] = bodies = created(client)
      assert Enum.all?(bodies, &(&1["inference_credential_id"] == "creator-set"))
      refute Enum.any?(bodies, &(&1["inference_credential_id"] in ["owner-set", "collab-set"]))
    end

    test "a harness the creator has not connected is disabled and refused", ctx do
      connections(%{ctx.creator.id => [:claude], ctx.collab.id => [:claude, :codex]})
      client = fountain([], verify: false)
      stub(Ravix.MachineCache, :machine_for_track, fn _, _, _ -> {:ok, nil} end)

      assert {:ok, options} = Tracks.thread_options(ctx.collab, ctx.track.id)
      assert options.billing == :creator
      assert options.owner_login == ctx.creator.login
      refute options.owner?
      assert %{connected: false} = Enum.find(options.runtimes, &(&1.runtime == "codex"))

      assert {:ok, %{owner?: true}} = Tracks.thread_options(ctx.creator, ctx.track.id)

      assert {:error, {:conflict, "agent_not_connected", message}} =
               start_thread(ctx.collab, ctx.track, "codex")

      assert message =~ ctx.creator.login
      assert created(client) == []
    end

    test "a paused harness refuses new threads with its reason", ctx do
      connections(%{ctx.creator.id => [:claude]})
      agent_id = ctx.project.agent_id

      client =
        fountain([
          {%{method: "GET", path: "/api/agents/#{agent_id}"},
           agent(agent_id, "owner-set", ["creator-set"])}
        ])

      until = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      pause =
        Billing.from_error(
          %Error{code: "chatgpt_grant_unusable", grant_reason: "exhausted", until: until},
          ctx.creator,
          "claude"
        )

      :ok = Tracks.Store.pause_billing(ctx.track.id, "claude", pause)

      assert {:error, {:conflict, "payer_paused", "Paused: @" <> _ = message}} =
               start_thread(ctx.collab, ctx.track, "claude")

      assert message =~ "ChatGPT subscription is out of quota until"
      assert created(client) == []
    end

    test "a creator who has connected nothing, or whose account is gone, is never replaced",
         ctx do
      connections(%{ctx.owner.id => [:claude]})
      client = fountain([], verify: false)

      Repo.update!(Ecto.Changeset.change(ctx.creator, credential_set_id: nil))

      assert {:error, {:conflict, "payer_not_connected", _}} =
               start_thread(ctx.collab, ctx.track, "claude")

      Repo.update!(Ecto.Changeset.change(ctx.track, payer_user_id: nil))

      assert {:error, {:conflict, "payer_unavailable", _}} =
               start_thread(ctx.collab, ctx.track, "claude")

      assert created(client) == []
    end

    test "the switch turned off later leaves the recorded payer in place", ctx do
      switch(false)
      connections(%{ctx.creator.id => [:claude], ctx.owner.id => [:claude]})
      client = thread_fountain(ctx, 1)
      assert {:ok, _} = start_thread(ctx.owner, ctx.track, "claude")
      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
    end

    test "a refused creator credential at thread start pauses the harness and says whose", ctx do
      connections(%{ctx.creator.id => [:codex]})
      agent_id = ctx.project.agent_id
      until = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

      Repo.insert!(%Ravix.Projects.RuntimeAgent{
        project_id: ctx.project.id,
        runtime: "codex",
        agent_id: "codex-agent",
        credential_set_id: "owner-set"
      })

      client =
        fountain(
          [
            {%{method: "GET", path: "/api/sandboxes/#{ctx.track.sandbox_id}"},
             {200, [],
              %{data: %{id: ctx.track.sandbox_id, sprite_name: "disk", agent_id: agent_id}}}},
            {%{method: "GET", path: "/api/agents/codex-agent"},
             agent("codex-agent", "owner-set", ["creator-set"])}
          ] ++
            clean(ctx.project.environment_id, "track-vault") ++
            [
              {%{method: "POST", path: "/api/conversations"},
               {409, [],
                %{
                  error: "chatgpt_grant_unusable",
                  reason: "exhausted",
                  grant_id: Ecto.UUID.generate(),
                  grant: "ravix:#{ctx.creator.id}",
                  until: DateTime.to_iso8601(until),
                  message: "has used its Codex allowance"
                }}}
            ]
        )

      assert {:error, {:conflict, "chatgpt_grant_unusable", message}} =
               start_thread(ctx.collab, ctx.track, "codex")

      assert message =~ "@#{ctx.creator.login}'s ChatGPT subscription is out of quota until"
      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
      track = Tracks.Store.get_track(ctx.track.id)
      assert %{"codex" => %{"until" => stored}} = track.billing_pauses
      assert {:ok, ^until, 0} = DateTime.from_iso8601(stored)
    end
  end

  # ── every launch path ─────────────────────────────────────────────────
  #
  # There is no live check before activation, so these are the guard against
  # the silent fallback: each path that creates a creator-billed conversation
  # sends exactly the creator's set, and a launch that names nothing (the
  # agent's default, the owner's set) or another set is refused before any
  # request reaches Fountain, whatever built it.

  describe "every creator-billed launch path" do
    setup ctx do
      connections(%{ctx.creator.id => [:claude], ctx.owner.id => [:claude]})
      %{track: creator_billed(ready_track(ctx))}
    end

    # The operator's evidence for each launch: one info line, ids only.
    defp launch_log(fun) do
      previous_level = Logger.level()
      Logger.configure(level: :info)

      try do
        ExUnit.CaptureLog.capture_log([level: :info], fun)
      after
        Logger.configure(level: previous_level)
      end
    end

    defp launch_line(track, ctx),
      do:
        "ravix: creator billing launch track=#{track.id} payer=#{ctx.creator.id} set=creator-set agent=#{ctx.project.agent_id}"

    # `Billing.bind/3` is where a path puts the set; forcing it to produce a
    # wrong launch shows the door itself refuses, not just the builder.
    defp mislabel(set) do
      stub(Billing, :bind, fn launch, _track, _project ->
        {:ok, %{launch | inference_credential_id: set}}
      end)
    end

    defp open_op(ctx, track, phase, resources \\ %{}) do
      {:ok, op} = Tracks.Sandbox.Store.begin_operation(track.id, track.sandbox_generation, :open)

      {:ok, op} =
        Tracks.Sandbox.Store.update_operation(op, %{
          phase: phase,
          resource_ids:
            Map.merge(
              %{
                "agent_id" => ctx.project.agent_id,
                "environment_id" => ctx.project.environment_id,
                "vault_id" => "track-vault",
                "source_vault_id" => ctx.project.vault_id,
                "runtime" => "claude",
                "model" => "anthropic/claude-opus-5-5",
                "channel_id" => "open-channel"
              },
              resources
            )
        })

      op
    end

    defp opening_fountain(ctx, vault, post) do
      agent_id = ctx.project.agent_id

      FakeTransport.client(
        clean(ctx.project.environment_id, vault) ++
          [
            {%{method: "GET", path: "/api/agents/#{agent_id}"},
             agent(agent_id, "owner-set", ["creator-set"])}
          ] ++ post,
        verify: false
      )
    end

    defp opened,
      do: [
        {%{method: "POST", path: "/api/conversations"},
         {201, [], %{data: %{id: "opened", sandbox_id: "fresh"}}}}
      ]

    test "thread start", ctx do
      client =
        fountain(
          [
            {%{method: "GET", path: "/api/agents/#{ctx.project.agent_id}"},
             agent(ctx.project.agent_id, "owner-set", ["creator-set"])}
          ] ++
            clean(ctx.project.environment_id, "track-vault") ++ opened(),
          verify: false
        )

      log = launch_log(fn -> assert {:ok, _} = start_thread(ctx.collab, ctx.track, "claude") end)
      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
      assert log =~ launch_line(ctx.track, ctx)
      refute log =~ "owner-set"

      for bad <- [nil, "owner-set", "collab-set"] do
        mislabel(bad)

        client =
          fountain(
            [
              {%{method: "GET", path: "/api/agents/#{ctx.project.agent_id}"},
               agent(ctx.project.agent_id, "owner-set", ["creator-set"])}
            ] ++
              clean(ctx.project.environment_id, "track-vault"),
            verify: false
          )

        assert {:error, {:conflict, "payer_mismatch", _}} =
                 start_thread(ctx.collab, ctx.track, "claude")

        assert created(client) == []
      end
    end

    test "the opening conversation", ctx do
      track = creator_billed(ready_track(ctx, conversation_id: nil, sandbox_id: nil))
      client = opening_fountain(ctx, "track-vault", opened())

      log =
        launch_log(fn ->
          Tracks.Sandbox.advance(client, open_op(ctx, track, "vault_ready").id)
        end)

      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
      assert log =~ launch_line(track, ctx)

      for bad <- [nil, "owner-set"] do
        mislabel(bad)
        track = creator_billed(ready_track(ctx, conversation_id: nil, sandbox_id: nil))
        client = opening_fountain(ctx, "track-vault", [])
        Tracks.Sandbox.advance(client, open_op(ctx, track, "vault_ready").id)
        assert created(client) == []
        assert %{setup_error_code: "payer_mismatch"} = Tracks.Store.get_track(track.id)
      end
    end

    test "an admission still pending retries the open instead of failing it", ctx do
      track = creator_billed(ready_track(ctx, conversation_id: nil, sandbox_id: nil))
      op = open_op(ctx, track, "vault_ready")
      agent_id = ctx.project.agent_id

      client =
        FakeTransport.client(
          clean(ctx.project.environment_id, "track-vault") ++
            [
              {%{method: "GET", path: "/api/agents/#{agent_id}"},
               agent(agent_id, "owner-set", [])},
              {%{method: "PUT", path: "/api/agents/#{agent_id}"},
               agent(agent_id, "owner-set", [])},
              {%{method: "GET", path: "/api/agents/#{agent_id}"},
               agent(agent_id, "owner-set", [])}
            ],
          verify: false
        )

      Tracks.Sandbox.advance(client, op.id)
      assert created(client) == []

      assert %{phase: "vault_ready", retry_at: %DateTime{}, error: nil} =
               Tracks.Sandbox.Store.get_operation(op.id)

      assert %{setup_error_code: "payer_not_admitted", sandbox_state: state} =
               Tracks.Store.get_track(track.id)

      refute state == :failed
    end

    test "a retried open", ctx do
      track = creator_billed(ready_track(ctx, conversation_id: nil, sandbox_id: nil))
      op = open_op(ctx, track, "failed")
      Repo.update!(Ecto.Changeset.change(Tracks.Store.get_track(track.id), setup_state: "failed"))
      stub(Fountain, :client, fn -> FakeTransport.client([], verify: false) end)
      assert :ok = Tracks.retry(ctx.creator, track.id)

      client =
        opening_fountain(ctx, "retry-vault", opened())
        |> tap(fn client ->
          FakeTransport.expect(
            client,
            %{method: "POST", path: "/api/vaults/#{ctx.project.vault_id}/copy"},
            {201, [], %{data: %{id: "retry-vault", name: "copy", secret_count: 0}}}
          )
        end)

      Tracks.Sandbox.advance(client, op.id)

      assert [%{"inference_credential_id" => "creator-set", "vault_id" => "retry-vault"}] =
               created(client)
    end

    test "a credential-recovery successor", ctx do
      {:ok, _} = Tracks.Store.recover_credentials(ctx.track, ctx.track.id)
      thread = Tracks.Store.thread(ctx.track.id)
      assert thread.credential_recovery

      client =
        opening_fountain(ctx, "track-vault", [
          {%{method: "POST", path: "/api/conversations"},
           {201, [], %{data: %{id: "successor", sandbox_id: ctx.track.sandbox_id}}}}
        ])

      log =
        launch_log(fn ->
          assert :rebound =
                   Tracks.CredentialRecovery.prepare(client, ctx.track, ctx.project, ctx.track.id)
        end)

      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
      assert log =~ launch_line(ctx.track, ctx)

      for bad <- [nil, "owner-set"] do
        mislabel(bad)
        track = creator_billed(ready_track(ctx))
        {:ok, _} = Tracks.Store.recover_credentials(track, track.id)
        client = opening_fountain(ctx, "track-vault", [])
        assert :waiting = Tracks.CredentialRecovery.prepare(client, track, ctx.project, track.id)
        assert created(client) == []
        assert %{"attempted" => false} = Tracks.Store.thread(track.id).credential_recovery
      end
    end

    test "a scheduled prompt opens a track its schedule's owner pays for", ctx do
      switch(true)
      agent_id = ctx.project.agent_id

      fountain(
        clean(ctx.project.environment_id, ctx.project.vault_id) ++
          [
            {%{method: "GET", path: "/api/agents/#{agent_id}"},
             agent(agent_id, "owner-set", ["creator-set"])}
          ],
        verify: false
      )

      {:ok, schedule} =
        Schedules.create(ctx.creator, ctx.project.id, %{
          name: "nightly",
          prompt: "check the build",
          frequency: :daily,
          time: ~T[03:00:00]
        })

      Schedules.Runner.run(schedule.id, DateTime.add(schedule.next_run_at, 1))
      [track] = Enum.filter(Tracks.Store.tracks_of(ctx.project.id), &(&1.id != ctx.track.id))
      assert {track.billing_policy, track.payer_user_id} == {:creator, ctx.creator.id}
    end
  end

  # ── launches ──────────────────────────────────────────────────────────

  describe "binding a launch" do
    test "a creator-billed launch naming nothing, or someone else, is refused", ctx do
      track = creator_billed(ready_track(ctx))

      launch = %Launch{
        agent_id: "a",
        environment_id: "e",
        vault_id: "v",
        sandbox_id: "s",
        channel_id: "c",
        title: "t",
        prompt: nil
      }

      assert {:error, {:conflict, "payer_mismatch", _}} =
               Billing.verify(launch, track, ctx.project)

      assert {:error, {:conflict, "payer_mismatch", _}} =
               Billing.verify(
                 %{launch | inference_credential_id: "owner-set"},
                 track,
                 ctx.project
               )

      assert {:ok, %{inference_credential_id: "creator-set"}} =
               Billing.bind(launch, track, ctx.project)
    end

    test "an owner-billed track binds exactly as before creator billing", ctx do
      track = ready_track(ctx)

      launch = %Launch{
        agent_id: "a",
        environment_id: "e",
        vault_id: "v",
        sandbox_id: "s",
        channel_id: "c",
        title: "t",
        prompt: nil
      }

      stub(Ravix.Config, :dedicated_opens_enabled?, fn _ -> false end)
      assert {:ok, %{inference_credential_id: nil}} = Billing.bind(launch, track, ctx.project)

      stub(Ravix.Config, :dedicated_opens_enabled?, fn user -> user.id == ctx.owner.id end)

      assert {:ok, %{inference_credential_id: "owner-set"}} =
               Billing.bind(launch, track, ctx.project)

      assert {:ok, ^launch} = Billing.verify(launch, track, ctx.project)
    end
  end

  # ── allowlist ─────────────────────────────────────────────────────────

  describe "the agent allowlist" do
    # A Fountain agent whose PUT replaces the whole list, as Fountain's does,
    # held in an Agent so concurrent writers see each other's writes.
    defp live_agent(agent_id, default, allowed, delay_ms) do
      {:ok, state} = Agent.start_link(fn -> allowed end)

      read = fn _call -> agent(agent_id, default, Agent.get(state, & &1)) end

      write = fn call ->
        Process.sleep(delay_ms)
        Agent.update(state, fn _ -> call.body["allowed_inference_credential_ids"] end)
        agent(agent_id, default, Agent.get(state, & &1))
      end

      {state, read, write}
    end

    test "concurrent admissions of two creators both survive", ctx do
      agent_id = ctx.project.agent_id
      {state, read, write} = live_agent(agent_id, "owner-set", [], 50)

      client =
        FakeTransport.client(
          List.duplicate({%{method: "GET", path: "/api/agents/#{agent_id}"}, read}, 4) ++
            List.duplicate({%{method: "PUT", path: "/api/agents/#{agent_id}"}, write}, 2)
        )

      tasks =
        for set <- ["creator-a", "creator-b"],
            do: Task.async(fn -> RuntimeAgents.admit_payer(client, agent_id, set) end)

      assert Enum.map(tasks, &Task.await(&1, 15_000)) == [{:ok, agent_id}, {:ok, agent_id}]
      assert Enum.sort(Agent.get(state, & &1)) == ["creator-a", "creator-b"]
    end

    test "an admission Fountain does not confirm fails closed", ctx do
      agent_id = ctx.project.agent_id

      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/agents/#{agent_id}"}, agent(agent_id, "owner-set", [])},
          {%{method: "PUT", path: "/api/agents/#{agent_id}"}, agent(agent_id, "owner-set", [])},
          {%{method: "GET", path: "/api/agents/#{agent_id}"}, agent(agent_id, "owner-set", [])}
        ])

      assert {:error, {:conflict, "payer_not_admitted", _}} =
               RuntimeAgents.admit_payer(client, agent_id, "creator-set")
    end

    test "a held lock fails the admission closed rather than racing it", ctx do
      agent_id = ctx.project.agent_id
      test = self()

      holder =
        spawn(fn ->
          Ravix.Cluster.agent_allowlist(agent_id, fn ->
            send(test, :held)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :held
      client = FakeTransport.client([])
      Application.put_env(:ravix, :agent_allowlist_wait_ms, 100)
      on_exit(fn -> Application.delete_env(:ravix, :agent_allowlist_wait_ms) end)

      assert {:error, {:conflict, "payer_admission_busy", _}} =
               RuntimeAgents.admit_payer(client, agent_id, "creator-set")

      send(holder, :release)
    end

    test "the owner reconnecting keeps admitted creators while any track is creator-billed",
         ctx do
      creator_billed(ready_track(ctx))

      project =
        Repo.update!(Ecto.Changeset.change(ctx.project, credential_set_id: "old-owner-set"))

      agent_id = project.agent_id

      client =
        FakeTransport.client([
          {%{method: "GET", path: "/api/agents/#{agent_id}"},
           agent(agent_id, "old-owner-set", ["creator-set"])},
          {%{
             method: "PUT",
             path: "/api/agents/#{agent_id}",
             body: %{inference_credential_id: "owner-set"}
           }, agent(agent_id, "owner-set", ["creator-set"])}
        ])

      assert :ok = Projects.prepare_machine(project, client)
      [_, put] = FakeTransport.calls(client)
      refute Map.has_key?(put.body, "allowed_inference_credential_ids")
    end

    test "a runtime agent is created with an explicit list and then admits the creator", ctx do
      track = creator_billed(ready_track(ctx))
      connections(%{ctx.creator.id => [:codex]})

      client =
        fountain(
          [
            {%{method: "POST", path: "/api/agents"},
             fn call ->
               assert call.body["allowed_inference_credential_ids"] == []
               assert call.body["inference_credential_id"] == "owner-set"
               {201, [], %{data: %{id: "codex-agent"}}}
             end},
            {%{method: "GET", path: "/api/agents/codex-agent"},
             agent("codex-agent", "owner-set", [])},
            {%{
               method: "PUT",
               path: "/api/agents/codex-agent",
               body: %{allowed_inference_credential_ids: ["creator-set"]}
             }, agent("codex-agent", "owner-set", ["creator-set"])},
            {%{method: "GET", path: "/api/agents/codex-agent"},
             agent("codex-agent", "owner-set", ["creator-set"])}
          ] ++
            clean(ctx.project.environment_id, "track-vault") ++
            [
              {%{method: "POST", path: "/api/conversations"},
               {201, [], %{data: %{id: "codex-thread", sandbox_id: "disk"}}}}
            ]
        )

      assert {:ok, %{runtime: "codex"}} = start_thread(ctx.collab, track, "codex")
      assert [%{"inference_credential_id" => "creator-set"}] = created(client)
    end
  end

  # ── queue delivery ────────────────────────────────────────────────────

  describe "queued prompts on a creator-billed track" do
    setup ctx do
      track = creator_billed(ready_track(ctx))

      spec =
        Supervisor.child_spec({Ravix.PromptQueue.Server, name: nil, interval: false, wake: false},
          id: make_ref()
        )

      server = start_supervised!(spec)
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), server)

      for mod <- [
            Fountain,
            Ravix.Config,
            Inference,
            Ravix.MachineCache,
            Ravix.Previews,
            Ravix.Previews.Store
          ],
          do: allow(mod, self(), server)

      # The session-history scan a delivery makes before it sends: nothing new.
      stub(Fountain, :events_page, fn _, _, _ ->
        {:ok, %{events: [], next_cursor: nil, has_more: false}}
      end)

      %{track: track, server: server}
    end

    defp enqueue(track, user, text) do
      Ravix.PromptQueue.Store.enqueue(
        track.id,
        user.id,
        user.login,
        request_id(),
        %{prompt: text, images: []},
        nil
      )
    end

    defp read_idle(track),
      do:
        {%{method: "GET", path: "/api/conversations/#{track.conversation_id}"},
         {200, [],
          %{data: %{id: track.conversation_id, status: "idle", sandbox_id: track.sandbox_id}}}}

    defp tick(ctx), do: QueueServer.tick(ctx.server)

    # Queue tests keep each followed thread's stream open and quiet.
    defp queue_fountain(expectations, opts \\ []),
      do: fountain(expectations, Keyword.put(opts, :transport, Ravix.QueueStreamTransport))

    defp requests(client),
      do: Enum.reject(FakeTransport.calls(client), &String.ends_with?(&1.path, "/stream"))

    defp row(id), do: Ravix.PromptQueue.Store.get(id)

    test "a paused harness holds the prompt with its reason and sends nothing", ctx do
      connections(%{ctx.creator.id => [:claude]})
      client = queue_fountain([])
      pause = Billing.from_failure("usage limit reached", ctx.creator, "claude")
      :ok = Tracks.Store.pause_billing(ctx.track.id, "claude", pause)

      {:ok, item} = enqueue(ctx.track, ctx.collab, "waits")
      tick(ctx)

      assert %{status: :queued, error: "Paused: @" <> _ = message} = row(item.id)
      assert message =~ "#{ctx.creator.login}'s Anthropic API key is out of quota"
      assert requests(client) == []
    end

    test "the creator reconnecting lifts the pause and the saved prompt goes out", ctx do
      connections(%{ctx.creator.id => [:claude]})
      pause = Billing.from_failure("401 unauthorized", ctx.creator, "claude")
      :ok = Tracks.Store.pause_billing(ctx.track.id, "claude", pause)
      {:ok, item} = enqueue(ctx.track, ctx.collab, "after reconnect")

      queue_fountain([])
      tick(ctx)
      assert row(item.id).status == :queued

      later = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()

      Repo.update!(
        Ecto.Changeset.change(ctx.creator,
          credential_connected_at: %{"claude:subscription" => later}
        )
      )

      client =
        queue_fountain([
          read_idle(ctx.track),
          {%{method: "POST", path: "/api/conversations/#{ctx.track.conversation_id}/prompts"},
           {202, [], %{data: %{ok: true}}}}
        ])

      tick(ctx)
      assert row(item.id).status == :sent

      assert [%{body: %{"prompt" => prompt}}] =
               Enum.filter(requests(client), &(&1.method == "POST"))

      assert prompt =~ "after reconnect"
    end

    test "a ChatGPT refusal on send pauses the harness with its reset time; the prompt waits",
         ctx do
      connections(%{ctx.creator.id => [:claude]})
      until = DateTime.utc_now() |> DateTime.add(3 * 3600, :second) |> DateTime.truncate(:second)

      queue_fountain([
        read_idle(ctx.track),
        {%{method: "POST", path: "/api/conversations/#{ctx.track.conversation_id}/prompts"},
         {409, [],
          %{
            error: "chatgpt_grant_unusable",
            reason: "exhausted",
            grant_id: Ecto.UUID.generate(),
            grant: "ravix:#{ctx.creator.id}",
            until: DateTime.to_iso8601(until),
            message: "has used its Codex allowance"
          }}}
      ])

      {:ok, item} = enqueue(ctx.track, ctx.collab, "held")
      tick(ctx)

      assert %{status: :queued, error_code: "chatgpt_grant_unusable", error: message} =
               row(item.id)

      assert message =~ "@#{ctx.creator.login}'s ChatGPT subscription is out of quota until"
      assert %{"claude" => %{"until" => _}} = Tracks.Store.get_track(ctx.track.id).billing_pauses

      client = queue_fountain([])
      tick(ctx)
      assert row(item.id).status == :queued
      assert requests(client) == []
    end

    test "a rotated credential's successor keeps the creator as payer", ctx do
      connections(%{ctx.creator.id => [:claude], ctx.owner.id => [:claude]})
      agent_id = ctx.project.agent_id
      old = ctx.track.conversation_id

      client =
        queue_fountain(
          [
            read_idle(ctx.track),
            {%{method: "POST", path: "/api/conversations/#{old}/prompts"},
             {409, [],
              %{
                error: "inference_source_changed",
                message: "the conversation's credential source was changed"
              }}},
            {%{method: "GET", path: "/api/agents/#{agent_id}"},
             agent(agent_id, "owner-set", ["creator-set"])}
          ] ++
            clean(ctx.project.environment_id, "track-vault") ++
            [
              {%{method: "POST", path: "/api/conversations"},
               {201, [], %{data: %{id: "successor", sandbox_id: ctx.track.sandbox_id}}}},
              {%{method: "GET", path: "/api/conversations/successor"},
               {200, [],
                %{data: %{id: "successor", status: "idle", sandbox_id: ctx.track.sandbox_id}}}},
              {%{method: "POST", path: "/api/conversations/successor/prompts"},
               {202, [], %{data: %{ok: true}}}}
            ],
          verify: false
        )

      stub(Fountain, :events_page, fn _, _, _ ->
        {:ok, %{events: [], next_cursor: nil, has_more: false}}
      end)

      {:ok, item} = enqueue(ctx.track, ctx.collab, "after rotation")
      tick(ctx)
      assert %{status: :queued, error_code: "inference_source_changed"} = row(item.id)
      tick(ctx)
      tick(ctx)

      assert [%{"inference_credential_id" => "creator-set", "sandbox_id" => sandbox}] =
               created(client)

      assert sandbox == ctx.track.sandbox_id
      assert Tracks.Store.thread(ctx.track.id).conversation_id == "successor"
      assert row(item.id).status == :sent
    end
  end

  # ── existing tracks ───────────────────────────────────────────────────

  test "tracks opened before the switch stay owner-billed with it on", ctx do
    switch(true)
    track = ready_track(ctx)
    assert is_nil(track.billing_policy)
    connections(%{ctx.owner.id => [:claude], ctx.creator.id => [:claude]})
    stub(Ravix.Config, :dedicated_opens_enabled?, fn user -> user.id == ctx.owner.id end)

    client =
      fountain([
        {%{method: "POST", path: "/api/conversations"},
         {201, [], %{data: %{id: "legacy-thread", sandbox_id: "disk"}}}}
      ])

    assert {:ok, _} = start_thread(ctx.collab, track, "claude")
    assert [%{"inference_credential_id" => "owner-set"}] = created(client)

    assert Track.payer(Tracks.Store.get_track(track.id), ctx.project) ==
             {:legacy_owner, ctx.owner.id}

    assert Tracks.Store.get_track(track.id).billing_pauses == %{}
  end

  # ── pauses ────────────────────────────────────────────────────────────

  describe "pauses" do
    test "a ChatGPT refusal carries its reason and reset time" do
      payer = %Ravix.Accounts.User{id: "u", login: "creator"}
      until = ~U[2030-01-01 15:00:00Z]

      pause =
        Billing.from_error(
          %Error{code: "chatgpt_grant_unusable", grant_reason: "exhausted", until: until},
          payer,
          "codex"
        )

      assert Billing.message(pause) ==
               "Paused: @creator's ChatGPT subscription is out of quota until Jan 1, 15:00 UTC."

      revoked =
        Billing.from_error(
          %Error{code: "chatgpt_grant_unusable", grant_reason: "revoked"},
          payer,
          "codex"
        )

      assert Billing.message(revoked) == "Paused: @creator's ChatGPT subscription was revoked."
      assert is_nil(Billing.from_error(%Error{code: "sandbox_at_capacity"}, payer, "codex"))
    end

    test "Fountain's error body is read into a bounded reason and time" do
      body = %{
        "error" => "chatgpt_grant_unusable",
        "reason" => "exhausted",
        "until" => "2030-01-01T15:00:00Z"
      }

      error =
        Error.from_sdk(%Elixir.Fountain.Error{
          status: 409,
          code: "chatgpt_grant_unusable",
          body: body
        })

      assert error.grant_reason == "exhausted"
      assert error.until == ~U[2030-01-01 15:00:00Z]

      odd =
        Error.from_sdk(%Elixir.Fountain.Error{
          status: 409,
          code: "chatgpt_grant_unusable",
          body: %{"reason" => "made_up", "until" => "soon"}
        })

      assert {odd.grant_reason, odd.until} == {nil, nil}
    end

    test "a Claude failure pauses on auth or quota text, says until only when it can" do
      payer = %Ravix.Accounts.User{
        id: "u",
        login: "creator",
        credential_connected_at: %{"claude:subscription" => "2026-09-01T00:00:00Z"}
      }

      quota =
        Billing.from_failure(~s({"reason":"acp: Claude AI usage limit reached"}), payer, "claude")

      assert quota["code"] == "credential_exhausted"
      assert is_nil(quota["until"])

      assert Billing.message(quota) =~
               "Paused: @creator's Claude subscription is out of quota. acp: Claude AI usage limit reached"

      reset = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()

      timed =
        Billing.from_failure(
          ~s({"reason":"Claude AI usage limit reached|#{reset}"}),
          payer,
          "claude"
        )

      assert {:ok, until, 0} = DateTime.from_iso8601(timed["until"])
      assert DateTime.to_unix(until) == reset

      far = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second) |> DateTime.to_unix()
      assert is_nil(Billing.from_failure("usage limit reached|#{far}", payer, "claude")["until"])

      auth =
        Billing.from_failure(
          ~s({"reason":"acp: 401 authentication_error: OAuth token has expired sk-ant-oat01-abcdefghijklmnop"}),
          payer,
          "claude"
        )

      assert Billing.message(auth) =~ "Paused: @creator's Claude subscription stopped working."
      refute Billing.message(auth) =~ "abcdefghijklmnop"

      key_payer = %{
        payer
        | credential_connected_at: %{"claude:api_key" => "2026-09-01T00:00:00Z"}
      }

      assert Billing.from_failure("invalid x-api-key", key_payer, "claude")["reason"] =~
               "Anthropic API key"

      for transient <- [
            "rate_limit_error: slow down",
            "stream disconnected",
            ~s({"reason":"acp: crashed"})
          ],
          do: assert(is_nil(Billing.from_failure(transient, payer, "claude")))
    end

    test "a pause lifts when the payer reconnects that agent, or its reset passes", ctx do
      track = creator_billed(ready_track(ctx))
      pause = Billing.from_failure("usage limit reached", ctx.creator, "claude")
      :ok = Tracks.Store.pause_billing(track.id, "claude", pause)
      track = Tracks.Store.get_track(track.id)
      assert Billing.paused(track, "claude", ctx.creator)
      refute Billing.paused(track, "codex", ctx.creator)

      later = DateTime.utc_now() |> DateTime.add(5, :second) |> DateTime.to_iso8601()
      codex = %{ctx.creator | credential_connected_at: %{"codex:api_key" => later}}
      assert Billing.paused(track, "claude", codex)
      claude = %{ctx.creator | credential_connected_at: %{"claude:api_key" => later}}
      refute Billing.paused(track, "claude", claude)

      timed = %{pause | "until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))}
      :ok = Tracks.Store.pause_billing(track.id, "claude", timed)
      track = Tracks.Store.get_track(track.id)
      assert Billing.paused(track, "claude", ctx.creator)
      refute Billing.paused(track, "claude", ctx.creator, DateTime.add(DateTime.utc_now(), 120))
    end

    test "only the creator can try again, and only the pause they saw", ctx do
      track = creator_billed(ready_track(ctx))
      pause = Billing.from_failure("usage limit reached", ctx.creator, "claude")
      :ok = Tracks.Store.pause_billing(track.id, "claude", pause)

      assert {:error, {:forbidden, _}} = Tracks.resume_billing(ctx.collab, track.id, "claude")
      assert {:error, :not_found} = Tracks.resume_billing(insert_user(), track.id, "claude")
      assert :ok = Tracks.resume_billing(ctx.creator, track.id, "claude")
      assert Tracks.Store.get_track(track.id).billing_pauses == %{}
      assert {:error, :not_found} = Tracks.resume_billing(ctx.creator, track.id, "claude")

      :ok = Tracks.Store.pause_billing(track.id, "claude", pause)
      newer = %{pause | "at" => DateTime.to_iso8601(DateTime.utc_now())}
      :ok = Tracks.Store.pause_billing(track.id, "claude", newer)
      assert {:error, :stale_pause} = Billing.resume(track, "claude", pause)
    end

    test "a failed turn on a creator-billed track pauses its harness once, while recent", ctx do
      track = creator_billed(ready_track(ctx))
      now = DateTime.utc_now()

      failed = fn at, reason ->
        [
          %{
            "id" => 1,
            "kind" => "stage",
            "stage" => "turn",
            "state" => "started",
            "turn_id" => "t",
            "ts" => DateTime.to_iso8601(at)
          },
          %{
            "id" => 2,
            "kind" => "stage",
            "stage" => "turn",
            "state" => "failed",
            "turn_id" => "t",
            "ts" => DateTime.to_iso8601(at),
            "data" => Jason.encode!(%{"reason" => reason})
          }
        ]
      end

      old = failed.(DateTime.add(now, -3600, :second), "acp: 401 unauthorized")
      assert :ok = Billing.observe_turn(track, ctx.project, "claude", old, now)
      assert Tracks.Store.get_track(track.id).billing_pauses == %{}

      recent = failed.(now, "acp: 401 unauthorized")
      assert :ok = Billing.observe_turn(track, ctx.project, "claude", recent, now)

      assert %{"claude" => %{"code" => "credential_rejected"}} =
               Tracks.Store.get_track(track.id).billing_pauses

      legacy = ready_track(ctx)
      assert :ok = Billing.observe_turn(legacy, ctx.project, "claude", recent, now)
      assert Tracks.Store.get_track(legacy.id).billing_pauses == %{}

      structured = [
        %{
          "id" => 3,
          "kind" => "stage",
          "stage" => "provision",
          "state" => "failed",
          "ts" => DateTime.to_iso8601(now),
          "data" =>
            Jason.encode!(%{
              "reason" => "chatgpt_grant_unusable",
              "grant_reason" => "exhausted",
              "until" => "2030-01-01T15:00:00Z"
            })
        }
      ]

      assert :ok = Billing.observe_turn(track, ctx.project, "codex", structured, now)

      assert %{"codex" => %{"until" => "2030-01-01T15:00:00Z"}} =
               Tracks.Store.get_track(track.id).billing_pauses
    end
  end

  test "settling a failed turn on a creator-billed thread pauses its harness", ctx do
    track = creator_billed(ready_track(ctx))
    now = DateTime.to_iso8601(DateTime.utc_now())

    log = [
      %{
        "id" => 1,
        "kind" => "stage",
        "stage" => "turn",
        "state" => "started",
        "turn_id" => "t1",
        "ts" => now
      },
      %{
        "id" => 2,
        "kind" => "stage",
        "stage" => "turn",
        "state" => "failed",
        "turn_id" => "t1",
        "ts" => now,
        "data" => Jason.encode!(%{"reason" => "acp: {:error, \"401 invalid x-api-key\"}"})
      }
    ]

    stub(Fountain, :events, fn _client, id, _opts ->
      assert id == track.conversation_id
      {:ok, log}
    end)

    assert :ok = Tracks.Settlement.backfill(track.id, FakeTransport.client([]))

    assert %{"claude" => %{"code" => "credential_rejected", "reason" => reason}} =
             Tracks.Store.get_track(track.id).billing_pauses

    assert reason =~ "@#{ctx.creator.login}'s"

    # The same turn classified again pauses nothing a second time.
    :ok = Tracks.resume_billing(ctx.creator, track.id, "claude")
    assert :ok = Tracks.Settlement.backfill(track.id, FakeTransport.client([]))
    assert Tracks.Store.get_track(track.id).billing_pauses == %{}
  end

  # ── consent ───────────────────────────────────────────────────────────

  describe "the creator's consent note" do
    test "shown once, to the creator, the first time others can see the track", ctx do
      connections(%{ctx.creator.id => [:claude]})

      creator =
        Repo.update!(
          Ecto.Changeset.change(ctx.creator,
            credential_connected_at: %{"claude:subscription" => "2026-09-01T00:00:00Z"}
          )
        )

      track = creator_billed(ready_track(ctx, visibility: :private))

      assert {:ok, nil} = Tracks.billing_notice(ctx.creator, track.id)
      insert_track_member(track, ctx.collab)
      assert {:ok, nil} = Tracks.billing_notice(ctx.collab, track.id)
      assert {:ok, note} = Tracks.billing_notice(creator, track.id)
      assert note =~ "Collaborators' prompts here use your Claude subscription"
      assert %DateTime{} = Tracks.Store.get_track(track.id).billing_notice_at
      assert {:ok, nil} = Tracks.billing_notice(ctx.creator, track.id)
    end

    test "a project-visible track is visible to the project from the start", ctx do
      connections(%{ctx.creator.id => [:claude]})
      track = creator_billed(ready_track(ctx))
      assert {:ok, note} = Tracks.billing_notice(ctx.creator, track.id)
      assert is_binary(note)
      assert {:ok, nil} = Tracks.billing_notice(ctx.creator, ready_track(ctx).id)
    end
  end

  # ── inventory ─────────────────────────────────────────────────────────

  test "the activation inventory lists provider-named values by name only", ctx do
    other = insert_project(user: ctx.owner, vault_id: nil)
    env = ctx.project.environment_id

    client =
      FakeTransport.client(
        [
          {%{method: "GET", path: "/api/environments/#{env}"},
           {200, [], %{data: %{id: env, env_vars: %{"OPENAI_API_KEY" => "sk-should-not-appear"}}}}},
          {%{method: "GET", path: "/api/environments/#{env}/secrets"},
           {200, [], %{data: [%{key: "CLAUDE_CODE_OAUTH_TOKEN"}, %{key: "GITHUB_TOKEN"}]}}},
          {%{method: "GET", path: "/api/vaults/#{ctx.project.vault_id}/secrets"},
           {200, [], %{data: [%{key: "ANTHROPIC_API_KEY"}]}}},
          {%{method: "GET", path: "/api/environments/#{other.environment_id}"},
           {503, [], %{error: "unavailable"}}}
        ],
        verify: false
      )

    stub(Fountain, :client, fn -> client end)
    findings = Billing.inventory(client)

    assert %{
             environment: ["CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY"],
             vault: ["ANTHROPIC_API_KEY"]
           } =
             Enum.find(findings, &(&1.project_id == ctx.project.id))

    assert %{environment: {:error, _}} = Enum.find(findings, &(&1.project_id == other.id))
    refute inspect(findings) =~ "sk-should-not-appear"
  end
end
