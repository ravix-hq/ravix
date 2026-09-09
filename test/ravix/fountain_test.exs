defmodule Ravix.FountainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ravix.Fountain
  alias Ravix.Fountain.{Client, Error, FakeTransport}

  @auth {"authorization", "Bearer fake-key"}

  defp fake(expectations, opts \\ []), do: FakeTransport.client(expectations, opts)

  # ── the client ──────────────────────────────────────────────────────────

  describe "client/0" do
    test "builds from Ravix.Config.fountain/0 and an absent key means unconfigured" do
      previous_url = Ravix.Config.put(:fountain_url, "https://fountain.example/")
      previous_key = Ravix.Config.put(:fountain_api_key, nil)

      on_exit(fn ->
        Ravix.Config.put(:fountain_url, previous_url)
        Ravix.Config.put(:fountain_api_key, previous_key)
      end)

      client = Fountain.client()
      assert %Client{http: nil, base_url: "https://fountain.example"} = client
      refute Client.configured?(client)
      assert {:error, :unconfigured} = Fountain.catalog(client)

      Ravix.Config.put(:fountain_api_key, "key-1")
      client = Fountain.client()
      assert Client.configured?(client)
      assert client.http.transport == Elixir.Fountain.HTTP.Finch
      assert client.http.config.api_key == "key-1"
      assert client.http.config.base_url == "https://fountain.example"
      assert client.http.timeout == 60_000
    end

    test "every call on an unconfigured client answers {:error, :unconfigured}" do
      client = Client.new("https://fountain.example", nil)

      assert {:error, :unconfigured} = Fountain.catalog(client)
      assert {:error, :unconfigured} = Fountain.me(client)
      assert {:error, :unconfigured} = Fountain.create_environment(client, %{name: "x"})
      assert {:error, :unconfigured} = Fountain.get_environment(client, "e")
      assert {:error, :unconfigured} = Fountain.update_environment(client, "e", %{})
      assert {:error, :unconfigured} = Fountain.delete_environment(client, "e")
      assert {:error, :unconfigured} = Fountain.create_vault(client, %{name: "x"})
      assert {:error, :unconfigured} = Fountain.delete_vault(client, "v")
      assert {:error, :unconfigured} = Fountain.create_agent(client, %{})
      assert {:error, :unconfigured} = Fountain.get_agent(client, "a")
      assert {:error, :unconfigured} = Fountain.update_agent(client, "a", %{})
      assert {:error, :unconfigured} = Fountain.delete_agent(client, "a")
      assert {:error, :unconfigured} = Fountain.put_secret(client, :vaults, "v", "K", "v")
      assert {:error, :unconfigured} = Fountain.delete_secret(client, :vaults, "v", "K")
      assert {:error, :unconfigured} = Fountain.secret_keys(client, :vaults, "v")
      assert {:error, :unconfigured} = Fountain.list_conversations(client)
      assert {:error, :unconfigured} = Fountain.get_conversation(client, "c")

      assert {:error, :unconfigured} =
               Fountain.create_conversation(client, %{agent_id: "a", channel_id: "ch"})

      assert {:error, :unconfigured} = Fountain.prompt(client, "c", "hi")
      assert {:error, :unconfigured} = Fountain.interrupt(client, "c")
      assert {:error, :unconfigured} = Fountain.terminate(client, "c")
      assert {:error, :unconfigured} = Fountain.turns(client, "c")
      assert {:error, :unconfigured} = Fountain.events(client, "c")
      assert {:error, :unconfigured} = Fountain.events_page(client, "c")
      assert {:error, :unconfigured} = Fountain.stream_events(client, "c")
      assert {:error, :unconfigured} = Fountain.each_event(client, "c", fn _ -> :halt end)
      assert {:error, :unconfigured} = Fountain.sandbox(client, "s")
      assert {:error, :unconfigured} = Fountain.listing(client, "s", "/")
      assert {:error, :unconfigured} = Fountain.file(client, "s", "/a")
      assert {:error, :unconfigured} = Fountain.diff(client, "s", "/a")
    end

    test "an empty key is no key" do
      refute Client.configured?(Client.new("https://fountain.example", ""))
    end
  end

  # ── what this Fountain can do ───────────────────────────────────────────

  describe "catalog/1 and me/1" do
    test "catalog sends the bearer key and unwraps data" do
      client =
        fake([
          {%{
             method: "GET",
             path: "/api/catalog",
             headers: [@auth, {"accept", "application/json"}]
           },
           {200, [],
            %{data: %{runtimes: ["claude"], models: %{claude: ["anthropic/claude-opus-5"]}}}}}
        ])

      assert {:ok, %{"runtimes" => ["claude"], "models" => %{"claude" => [_]}}} =
               Fountain.catalog(client)

      [call] = FakeTransport.calls(client)
      assert call.body == nil
      refute List.keymember?(call.headers, "content-type", 0)
    end

    test "me accepts a body with or without the data wrapper" do
      client =
        fake([
          {%{method: "GET", path: "/api/auth/me"}, {200, [], %{id: "u1", email: "a@b.c"}}},
          {%{method: "GET", path: "/api/auth/me"},
           {200, [], %{data: %{id: "u2", email: "d@e.f"}}}}
        ])

      assert {:ok, %{"id" => "u1", "email" => "a@b.c"}} = Fountain.me(client)
      assert {:ok, %{"id" => "u2"}} = Fountain.me(client)
    end
  end

  # ── environments, vaults, agents ────────────────────────────────────────

  describe "environments" do
    test "create posts the body as JSON" do
      body = %{name: "Ravix · demo", repositories: [], packages: %{}, setup_script: ""}

      client =
        fake([
          {%{
             method: "POST",
             path: "/api/environments",
             body: body,
             headers: [{"content-type", "application/json"}]
           }, {201, [], %{data: %{id: "env-1", name: "Ravix · demo"}}}}
        ])

      assert {:ok, %{"id" => "env-1"}} = Fountain.create_environment(client, body)
    end

    test "get escapes the id, update is a PUT in place, delete is :ok on 204" do
      client =
        fake([
          {%{method: "GET", path: "/api/environments/env%2F1"},
           {200, [], %{data: %{id: "env/1"}}}},
          {%{method: "PUT", path: "/api/environments/env-1", body: %{setup_script: "npm ci"}},
           {200, [], %{data: %{id: "env-1", setup_script: "npm ci"}}}},
          {%{method: "DELETE", path: "/api/environments/env-1"}, {204, [], nil}}
        ])

      assert {:ok, %{"id" => "env/1"}} = Fountain.get_environment(client, "env/1")

      assert {:ok, %{"setup_script" => "npm ci"}} =
               Fountain.update_environment(client, "env-1", %{setup_script: "npm ci"})

      assert :ok = Fountain.delete_environment(client, "env-1")
    end
  end

  describe "vaults" do
    test "create and delete" do
      client =
        fake([
          {%{method: "POST", path: "/api/vaults", body: %{name: "Ravix · demo"}},
           {201, [], %{data: %{id: "vault-1", name: "Ravix · demo"}}}},
          {%{method: "DELETE", path: "/api/vaults/vault-1"}, {204, [], ""}}
        ])

      assert {:ok, %{"id" => "vault-1"}} = Fountain.create_vault(client, %{name: "Ravix · demo"})
      assert :ok = Fountain.delete_vault(client, "vault-1")
    end

    test "a Fountain without vaults answers with its status, for the caller to treat as none" do
      client =
        fake([
          {%{method: "POST", path: "/api/vaults"}, {501, [], %{error: "not_implemented"}}}
        ])

      log =
        capture_log(fn ->
          assert {:error, %Error{status: 501, code: "not_implemented"}} =
                   Fountain.create_vault(client, %{name: "x"})
        end)

      assert log =~ "fountain 501 on POST /api/vaults"
    end
  end

  describe "agents" do
    test "create, get, update, delete" do
      agent = %{name: "Ravix · demo", model: "anthropic/claude-opus-5", runtime: "claude"}

      client =
        fake([
          {%{method: "POST", path: "/api/agents", body: agent},
           {201, [], %{data: %{id: "agent-1"}}}},
          {%{method: "GET", path: "/api/agents/agent-1"}, {200, [], %{data: %{id: "agent-1"}}}},
          {%{method: "PUT", path: "/api/agents/agent-1", body: %{system: "Be brief."}},
           {200, [], %{data: %{id: "agent-1", system: "Be brief."}}}},
          {%{method: "DELETE", path: "/api/agents/agent-1"}, {204, [], nil}}
        ])

      assert {:ok, %{"id" => "agent-1"}} = Fountain.create_agent(client, agent)
      assert {:ok, %{"id" => "agent-1"}} = Fountain.get_agent(client, "agent-1")

      assert {:ok, %{"system" => "Be brief."}} =
               Fountain.update_agent(client, "agent-1", %{system: "Be brief."})

      assert :ok = Fountain.delete_agent(client, "agent-1")
    end
  end

  # ── secrets ─────────────────────────────────────────────────────────────

  describe "secrets" do
    test "put is one POST with key and value, to the store named" do
      client =
        fake([
          {%{
             method: "POST",
             path: "/api/vaults/vault-1/secrets",
             body: %{key: "GITHUB_TOKEN", value: "ghs_abc"}
           }, {201, [], %{data: %{key: "GITHUB_TOKEN"}}}},
          {%{
             method: "POST",
             path: "/api/environments/env-1/secrets",
             body: %{key: "API_KEY", value: "v"}
           }, {201, [], %{data: %{key: "API_KEY"}}}}
        ])

      assert :ok = Fountain.put_secret(client, :vaults, "vault-1", "GITHUB_TOKEN", "ghs_abc")
      assert :ok = Fountain.put_secret(client, :environments, "env-1", "API_KEY", "v")
    end

    test "a failed write logs the path and the status, never the value" do
      client =
        fake([
          {%{method: "POST", path: "/api/vaults/vault-1/secrets"},
           {422, [],
            %{error: "invalid_key", message: "Keys are letters, digits and underscores."}}}
        ])

      log =
        capture_log(fn ->
          assert {:error, %Error{status: 422, code: "invalid_key", message: message}} =
                   Fountain.put_secret(
                     client,
                     :vaults,
                     "vault-1",
                     "bad key",
                     "super-secret-value"
                   )

          assert message == "Keys are letters, digits and underscores."
        end)

      assert log =~ "fountain 422 on POST /api/vaults/vault-1/secrets"
      refute log =~ "super-secret-value"
    end

    test "delete escapes the key; keys lists what is stored, never values" do
      client =
        fake([
          {%{method: "DELETE", path: "/api/environments/env-1/secrets/A%20B"}, {204, [], nil}},
          {%{method: "GET", path: "/api/vaults/vault-1/secrets"},
           {200, [], %{data: [%{key: "GITHUB_TOKEN", updated_at: "2026-09-09T00:00:00Z"}]}}},
          {%{method: "GET", path: "/api/environments/env-1/secrets"}, {200, [], %{data: nil}}}
        ])

      assert :ok = Fountain.delete_secret(client, :environments, "env-1", "A B")

      assert {:ok, [%{"key" => "GITHUB_TOKEN"}]} =
               Fountain.secret_keys(client, :vaults, "vault-1")

      assert {:ok, []} = Fountain.secret_keys(client, :environments, "env-1")
    end
  end

  # ── conversations ───────────────────────────────────────────────────────

  describe "list_conversations/2 and get_conversation/2" do
    test "lists for one agent or for all" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations", query: %{agent_id: "agent-1"}},
           {200, [], %{data: [%{id: "c1", status: "idle", sandbox_id: "sb-1", sandbox: nil}]}}},
          {%{method: "GET", path: "/api/conversations", query: %{}}, {200, [], %{data: []}}}
        ])

      assert {:ok, [%{"id" => "c1", "sandbox_id" => "sb-1"}]} =
               Fountain.list_conversations(client, "agent-1")

      assert {:ok, []} = Fountain.list_conversations(client)
    end

    test "get embeds the sandbox" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1"},
           {200, [],
            %{data: %{id: "c1", status: "running", sandbox: %{id: "sb-1", sprite_name: "sp-1"}}}}}
        ])

      assert {:ok, %{"sandbox" => %{"sprite_name" => "sp-1"}}} =
               Fountain.get_conversation(client, "c1")
    end
  end

  describe "create_conversation/2" do
    test "provisioning: the whole identity, persistent mode, the opening prompt, fresh" do
      expected = %{
        agent_id: "agent-1",
        environment_id: "env-1",
        vault_id: "vault-1",
        sandbox_mode: "persistent",
        title: "Fix the build",
        prompt: "Open the track.",
        channel_id: "ravix:p1:fix-the-build:1",
        fresh: true
      }

      client =
        fake([
          {%{method: "POST", path: "/api/conversations", body: expected},
           {201, [], %{data: %{id: "c1", status: "pending"}}}}
        ])

      assert {:ok, %{"id" => "c1"}} =
               Fountain.create_conversation(client, %{
                 agent_id: "agent-1",
                 environment_id: "env-1",
                 vault_id: "vault-1",
                 sandbox_id: nil,
                 title: "Fix the build",
                 channel_id: "ravix:p1:fix-the-build:1",
                 prompt: "Open the track."
               })
    end

    test "attaching: sandbox_id instead of a mode, no prompt, blanks left off" do
      expected = %{
        agent_id: "agent-1",
        environment_id: "env-1",
        sandbox_id: "sb-1",
        channel_id: "ravix:p1:next:1",
        fresh: true
      }

      client =
        fake([
          {%{method: "POST", path: "/api/conversations", body: expected},
           {201, [], %{data: %{id: "c2"}}}}
        ])

      assert {:ok, %{"id" => "c2"}} =
               Fountain.create_conversation(client, %{
                 agent_id: "agent-1",
                 environment_id: "env-1",
                 vault_id: nil,
                 sandbox_id: "sb-1",
                 title: "",
                 channel_id: "ravix:p1:next:1"
               })
    end

    test "an identity mismatch comes back with Fountain's code" do
      client =
        fake([
          {%{method: "POST", path: "/api/conversations"},
           {409, [],
            %{
              error: "sandbox_identity_mismatch",
              message: "The sandbox belongs to another identity."
            }}}
        ])

      capture_log(fn ->
        assert {:error, %Error{status: 409, code: "sandbox_identity_mismatch"} = error} =
                 Fountain.create_conversation(client, %{
                   agent_id: "agent-1",
                   channel_id: "ch",
                   sandbox_id: "sb-1"
                 })

        assert %{status: 409, code: "identity_mismatch"} = Error.as_http(error, "open this track")
      end)
    end
  end

  describe "prompt/4, interrupt/2, terminate/2, turns/2" do
    test "prompt sends the text, and images only when there are any" do
      image = %{data: "aGVsbG8=", media_type: "image/png"}

      client =
        fake([
          {%{method: "POST", path: "/api/conversations/c1/prompts", body: %{prompt: "hello"}},
           {202, [], %{data: %{ok: true}}}},
          {%{
             method: "POST",
             path: "/api/conversations/c1/prompts",
             body: %{prompt: "look", images: [image]}
           }, {202, [], %{data: %{ok: true}}}}
        ])

      assert :ok = Fountain.prompt(client, "c1", "hello")
      assert :ok = Fountain.prompt(client, "c1", "look", [image])
    end

    test "a machine at capacity is busy, and safe to retry" do
      client =
        fake([
          {%{method: "POST", path: "/api/conversations/c1/prompts"},
           {409, [], %{error: "sandbox_at_capacity", message: "The sandbox is taking a turn."}}},
          {%{method: "POST", path: "/api/conversations/c1/prompts"},
           {409, [], %{error: "conversation_busy"}}},
          {%{method: "POST", path: "/api/conversations/c1/prompts"},
           {422, [], %{error: "invalid"}}}
        ])

      capture_log(fn ->
        assert {:error, %Error{} = at_capacity} = Fountain.prompt(client, "c1", "x")
        assert Error.busy?(at_capacity)
        assert %{status: 409, code: "machine_busy"} = Error.as_http(at_capacity, "send")

        assert {:error, %Error{code: "conversation_busy", message: "conversation_busy"} = busy} =
                 Fountain.prompt(client, "c1", "x")

        assert Error.busy?(busy)

        assert {:error, %Error{status: 422} = rejected} = Fountain.prompt(client, "c1", "x")
        refute Error.busy?(rejected)
        assert Error.rejected?(rejected)
      end)
    end

    test "interrupt and terminate are signals, turns is a list" do
      client =
        fake([
          {%{method: "POST", path: "/api/conversations/c1/interrupt"},
           {200, [], %{data: %{ok: true}}}},
          {%{method: "POST", path: "/api/conversations/c1/terminate"},
           {200, [], %{data: %{ok: true}}}},
          {%{method: "GET", path: "/api/conversations/c1/turns"},
           {200, [],
            %{
              data: [
                %{
                  id: "t1",
                  prompt: "hi",
                  origin: "api",
                  status: "done",
                  inserted_at: "2026-09-09T00:00:00Z"
                }
              ]
            }}}
        ])

      assert :ok = Fountain.interrupt(client, "c1")
      assert :ok = Fountain.terminate(client, "c1")
      assert {:ok, [%{"id" => "t1", "prompt" => "hi"}]} = Fountain.turns(client, "c1")
    end

    test "terminate on a conversation that is gone is a not-found error" do
      client =
        fake([
          {%{method: "POST", path: "/api/conversations/gone/terminate"},
           {404, [], %{error: "not_found"}}}
        ])

      capture_log(fn ->
        assert {:error, %Error{status: 404, code: "not_found", kind: :not_found}} =
                 Fountain.terminate(client, "gone")
      end)
    end
  end

  # ── the transcript ──────────────────────────────────────────────────────

  describe "events_page/3 and events/3" do
    test "one page, with the cursor Fountain hands back" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/events", query: %{limit: "1000"}},
           {200, [], %{data: [%{id: 1, kind: "output"}], meta: %{has_more: true, next_cursor: 1}}}},
          {%{
             method: "GET",
             path: "/api/conversations/c1/events",
             query: %{limit: "50", after: "1", blocks: "true"}
           }, {200, [], %{data: [], meta: %{has_more: false, next_cursor: nil}}}}
        ])

      assert {:ok, %{events: [%{"id" => 1}], has_more: true, next_cursor: 1}} =
               Fountain.events_page(client, "c1")

      assert {:ok, %{events: [], has_more: false, next_cursor: 1}} =
               Fountain.events_page(client, "c1", after: 1, limit: 50, blocks: true)
    end

    test "reads every stored page, deduplicated and sorted by id" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/events", query: %{limit: "1000"}},
           {200, [],
            %{
              data: [%{id: 2, kind: "output"}, %{id: 1, kind: "stage"}],
              meta: %{has_more: true, next_cursor: 2}
            }}},
          {%{
             method: "GET",
             path: "/api/conversations/c1/events",
             query: %{limit: "1000", after: "2"}
           },
           {200, [],
            %{
              data: [%{id: 2, kind: "output"}, %{id: 3, kind: "output"}],
              meta: %{has_more: false}
            }}}
        ])

      assert {:ok, [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]} = Fountain.events(client, "c1")
    end

    test "a page without meta is the last page" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/events"}, {200, [], %{data: [%{id: 7}]}}}
        ])

      assert {:ok, [%{"id" => 7}]} = Fountain.events(client, "c1")
    end

    test "pagination that does not advance is an error rather than a loop" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/events", query: %{limit: "1000"}},
           {200, [], %{data: [%{id: 1}], meta: %{has_more: true, next_cursor: 1}}}},
          {%{
             method: "GET",
             path: "/api/conversations/c1/events",
             query: %{limit: "1000", after: "1"}
           }, {200, [], %{data: [%{id: 1}], meta: %{has_more: true, next_cursor: 1}}}}
        ])

      assert {:error, %Error{code: "pagination_stalled"} = error} = Fountain.events(client, "c1")

      assert %{status: 502, code: "fountain_unreachable"} =
               Error.as_http(error, "read this track")
    end

    test "a refused read carries the status" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/events"},
           {403, [], %{error: "forbidden"}}}
        ])

      capture_log(fn ->
        assert {:error, %Error{status: 403} = error} = Fountain.events(client, "c1")
        assert %{status: 502, code: "fountain_rejected"} = Error.as_http(error, "read this track")
      end)
    end
  end

  describe "stream_events/3 and each_event/4" do
    test "the live transcript, reconnected from the last event id" do
      first = [
        ": connected\n\n",
        FakeTransport.frame(1, "stage", %{id: 1, kind: "stage", stage: "turn", state: "started"}),
        FakeTransport.frame(2, "output", %{id: 2, kind: "output", stream: "acp", data: "hi"})
      ]

      second = [
        FakeTransport.frame(3, "stage", %{id: 3, kind: "stage", stage: "turn", state: "done"})
      ]

      client =
        fake([
          {%{
             method: "GET",
             path: "/api/conversations/c1/stream",
             query: %{},
             headers: [@auth, {"accept", "text/event-stream"}]
           }, {200, [{"content-type", "text/event-stream"}], first}},
          {%{
             method: "GET",
             path: "/api/conversations/c1/stream",
             headers: [{"last-event-id", "2"}]
           }, {200, [{"content-type", "text/event-stream"}], second}}
        ])

      test_pid = self()

      assert :ok =
               Fountain.each_event(
                 client,
                 "c1",
                 fn event ->
                   send(test_pid, {:event, event})
                   if event["state"] == "done", do: :halt
                 end,
                 retry_delay: 1
               )

      assert_received {:event, %{"id" => 1, "kind" => "stage", "state" => "started"}}
      assert_received {:event, %{"id" => 2, "kind" => "output", "data" => "hi"}}
      assert_received {:event, %{"id" => 3, "state" => "done"}}
      refute_received {:event, _}

      [first_call, second_call] = FakeTransport.calls(client)
      refute List.keymember?(first_call.headers, "last-event-id", 0)
      assert {"last-event-id", "2"} in second_call.headers
    end

    test "after: resumes from an id the caller already holds, as a lazy stream" do
      client =
        fake([
          {%{
             method: "GET",
             path: "/api/conversations/c1/stream",
             headers: [{"last-event-id", "41"}]
           }, {200, [], [FakeTransport.frame(42, "output", %{id: 42, kind: "output"})]}}
        ])

      assert {:ok, stream} = Fountain.stream_events(client, "c1", after: 41)
      assert [%{"id" => 42}] = Enum.take(stream, 1)
    end

    test "a refused stream is an error, not a raise" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/stream"},
           {404, [], %{error: "not_found"}}}
        ])

      capture_log(fn ->
        assert {:error, %Error{status: 404, code: "not_found"}} =
                 Fountain.each_event(client, "c1", fn _ -> :cont end, retry_delay: 1)
      end)
    end

    test "a connection that keeps failing gives up after max_retries" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/stream"}, {:error, :econnrefused}},
          {%{method: "GET", path: "/api/conversations/c1/stream"}, {:error, :econnrefused}}
        ])

      assert {:error, %Error{status: 0, kind: :connection} = error} =
               Fountain.each_event(client, "c1", fn _ -> :cont end,
                 retry_delay: 1,
                 max_retries: 1
               )

      assert Error.unreachable?(error)

      assert %{
               status: 502,
               code: "fountain_unreachable",
               message: "Could not reach Fountain to watch this track."
             } =
               Error.as_http(error, "watch this track")
    end
  end

  # ── reading the machine ─────────────────────────────────────────────────

  describe "sandboxes" do
    test "sandbox, listing, file and diff" do
      client =
        fake([
          {%{method: "GET", path: "/api/sandboxes/sb-1"},
           {200, [], %{data: %{id: "sb-1", sprite_name: "sp-1", status: "ready"}}}},
          {%{method: "GET", path: "/api/sandboxes/sb-1/files", query: %{path: "/workspace/repo"}},
           {200, [],
            %{
              data: %{
                path: "/workspace/repo",
                entries: [%{name: "src", type: "directory", size: nil}],
                truncated: false
              }
            }}},
          {%{
             method: "GET",
             path: "/api/sandboxes/sb-1/file",
             query: %{path: "/workspace/repo/a b.txt"}
           },
           {200, [],
            %{
              data: %{
                path: "/workspace/repo/a b.txt",
                size: 2,
                truncated: false,
                encoding: "utf-8",
                content: "hi"
              }
            }}},
          {%{method: "GET", path: "/api/sandboxes/sb-1/diff", query: %{path: "/workspace/repo"}},
           {200, [],
            %{
              data: %{
                path: "/workspace/repo",
                repo_root: "/workspace/repo",
                staged: false,
                ref: nil,
                diff: "",
                truncated: false
              }
            }}}
        ])

      assert {:ok, %{"sprite_name" => "sp-1"}} = Fountain.sandbox(client, "sb-1")

      assert {:ok, %{"entries" => [%{"type" => "directory"}]}} =
               Fountain.listing(client, "sb-1", "/workspace/repo")

      assert {:ok, %{"content" => "hi"}} =
               Fountain.file(client, "sb-1", "/workspace/repo/a b.txt")

      assert {:ok, %{"repo_root" => "/workspace/repo"}} =
               Fountain.diff(client, "sb-1", "/workspace/repo")
    end
  end

  # ── errors ──────────────────────────────────────────────────────────────

  describe "Error" do
    test "from_sdk keeps status and code and prefers Fountain's message, then the code" do
      with_message =
        Elixir.Fountain.Error.for_status(
          409,
          %{"error" => "sandbox_at_capacity", "message" => "Busy."},
          "POST",
          "u"
        )

      assert %Error{status: 409, code: "sandbox_at_capacity", message: "Busy.", kind: :api} =
               Error.from_sdk(with_message)

      code_only = Elixir.Fountain.Error.for_status(429, %{"error" => "rate_limited"}, "GET", "u")

      assert %Error{status: 429, code: "rate_limited", message: "rate_limited", kind: :rate_limit} =
               Error.from_sdk(code_only)

      bare = Elixir.Fountain.Error.for_status(502, "Bad Gateway", "GET", "u")

      assert %Error{status: 502, code: nil, message: "HTTP 502 Bad Gateway (GET u)"} =
               Error.from_sdk(bare)

      down = %Elixir.Fountain.Error{message: "GET u failed: econnrefused", kind: :connection}
      assert %Error{status: 0, code: nil, kind: :connection} = Error.from_sdk(down)
    end

    test "as_http mirrors asHttpError" do
      assert %{status: 503, code: "no_fountain"} = Error.as_http(:unconfigured, "x")
      assert %{status: 502, code: "fountain_rejected"} = Error.as_http(%Error{status: 401}, "x")

      assert %{status: 502, code: "fountain_rejected"} =
               Error.as_http(%Error{status: 403, code: "forbidden"}, "x")

      assert %{status: 409, code: "machine_busy"} =
               Error.as_http(%Error{status: 409, code: "sandbox_at_capacity"}, "x")

      assert %{status: 409, code: "identity_mismatch"} =
               Error.as_http(%Error{status: 409, code: "sandbox_identity_mismatch"}, "x")

      assert %{status: 502, code: "fountain_error", message: "boom"} =
               Error.as_http(%Error{status: 500, message: "boom"}, "x")

      assert %{status: 404, code: "not_found", message: "gone"} =
               Error.as_http(%Error{status: 404, code: "not_found", message: "gone"}, "x")

      assert %{
               status: 502,
               code: "fountain_unreachable",
               message: "Could not reach Fountain to build this project."
             } =
               Error.as_http(%Error{status: 0, kind: :connection}, "build this project")
    end
  end

  # ── the fake itself ─────────────────────────────────────────────────────

  describe "FakeTransport" do
    test "a request nothing expected fails the call and verify!" do
      client = fake([], verify: false)

      capture_log(fn ->
        assert {:error, %Error{status: 0, kind: :connection, message: message}} =
                 Fountain.catalog(client)

        assert message =~ "unexpected Fountain request GET /api/catalog"
      end)

      assert_raise RuntimeError, ~r/unexpected request\(s\): GET \/api\/catalog/, fn ->
        FakeTransport.verify!(client)
      end
    end

    test "an expectation never met fails verify!, and expect/3 adds one mid-test" do
      client = fake([], verify: false)

      FakeTransport.expect(
        client,
        %{method: "GET", path: "/api/catalog"},
        {200, [], %{data: %{}}}
      )

      assert_raise RuntimeError, ~r/never made: GET \/api\/catalog/, fn ->
        FakeTransport.verify!(client)
      end

      assert {:ok, %{}} = Fountain.catalog(client)
      assert :ok = FakeTransport.verify!(client)
    end

    test "a response may be a function of the call" do
      client =
        fake([
          {%{method: "GET", path: "/api/agents/agent-1"},
           fn call -> {200, [], %{data: %{id: Path.basename(call.path)}}} end}
        ])

      assert {:ok, %{"id" => "agent-1"}} = Fountain.get_agent(client, "agent-1")
    end
  end
end
