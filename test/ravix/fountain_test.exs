defmodule Ravix.FountainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ravix.Fountain
  alias Ravix.Fountain.{Client, Error, FakeTransport, Launch}
  alias Ravix.Fountain.Shapes
  alias Ravix.Fountain.Shapes.{Conversation, Sandbox, Turn}

  @auth {"authorization", "Bearer fake-key"}

  defp fake(expectations, opts \\ []), do: FakeTransport.client(expectations, opts)

  # All six fields, spelled out, with the values that put nothing on the
  # wire; each test then names only the ones it is about. `struct!/2` and not
  # a map merge, so a field misspelled in a test raises here rather than
  # silently testing the default.
  defp launch(fields \\ []) do
    %Launch{
      agent_id: "a",
      environment_id: nil,
      vault_id: nil,
      sandbox_id: nil,
      channel_id: "ch",
      prompt: nil
    }
    |> struct!(fields)
  end

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
      assert {:error, {:unconfigured, :fountain}} = Fountain.catalog(client)

      Ravix.Config.put(:fountain_api_key, "key-1")
      client = Fountain.client()
      assert Client.configured?(client)
      assert client.http.transport == Elixir.Fountain.HTTP.Finch
      assert client.http.config.api_key == "key-1"
      assert client.http.config.base_url == "https://fountain.example"
      assert client.http.timeout == 60_000
    end

    test "every call on an unconfigured client answers {:error, {:unconfigured, :fountain}}" do
      client = Client.new("https://fountain.example", nil)

      assert {:error, {:unconfigured, :fountain}} = Fountain.catalog(client)
      assert {:error, {:unconfigured, :fountain}} = Fountain.me(client)

      assert {:error, {:unconfigured, :fountain}} =
               Fountain.create_environment(client, %{name: "x"})

      assert {:error, {:unconfigured, :fountain}} = Fountain.get_environment(client, "e")
      assert {:error, {:unconfigured, :fountain}} = Fountain.update_environment(client, "e", %{})
      assert {:error, {:unconfigured, :fountain}} = Fountain.delete_environment(client, "e")
      assert {:error, {:unconfigured, :fountain}} = Fountain.create_vault(client, %{name: "x"})
      assert {:error, {:unconfigured, :fountain}} = Fountain.delete_vault(client, "v")
      assert {:error, {:unconfigured, :fountain}} = Fountain.create_agent(client, %{})
      assert {:error, {:unconfigured, :fountain}} = Fountain.get_agent(client, "a")
      assert {:error, {:unconfigured, :fountain}} = Fountain.update_agent(client, "a", %{})
      assert {:error, {:unconfigured, :fountain}} = Fountain.delete_agent(client, "a")

      assert {:error, {:unconfigured, :fountain}} =
               Fountain.put_secret(client, :vaults, "v", "K", "v")

      assert {:error, {:unconfigured, :fountain}} =
               Fountain.delete_secret(client, :vaults, "v", "K")

      assert {:error, {:unconfigured, :fountain}} = Fountain.secret_keys(client, :vaults, "v")
      assert {:error, {:unconfigured, :fountain}} = Fountain.list_conversations(client)
      assert {:error, {:unconfigured, :fountain}} = Fountain.get_conversation(client, "c")

      assert {:error, {:unconfigured, :fountain}} = Fountain.create_conversation(client, launch())

      assert {:error, {:unconfigured, :fountain}} = Fountain.prompt(client, "c", "hi")
      assert {:error, {:unconfigured, :fountain}} = Fountain.interrupt(client, "c")
      assert {:error, {:unconfigured, :fountain}} = Fountain.wake(client, "c")
      assert {:error, {:unconfigured, :fountain}} = Fountain.terminate(client, "c")
      assert {:error, {:unconfigured, :fountain}} = Fountain.turns(client, "c")
      assert {:error, {:unconfigured, :fountain}} = Fountain.turn_image(client, "c", "t", 0)
      assert {:error, {:unconfigured, :fountain}} = Fountain.events(client, "c")
      assert {:error, {:unconfigured, :fountain}} = Fountain.events_page(client, "c")
      assert {:error, {:unconfigured, :fountain}} = Fountain.stream_events(client, "c")

      assert {:error, {:unconfigured, :fountain}} =
               Fountain.each_event(client, "c", fn _ -> :halt end)

      assert {:error, {:unconfigured, :fountain}} = Fountain.sandbox(client, "s")
      assert {:error, {:unconfigured, :fountain}} = Fountain.listing(client, "s", "/")
      assert {:error, {:unconfigured, :fountain}} = Fountain.file(client, "s", "/a")
      assert {:error, {:unconfigured, :fountain}} = Fountain.diff(client, "s", "/a")
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

      assert {:ok, %Shapes.Catalog{runtimes: ["claude"]} = catalog} = Fountain.catalog(client)
      assert Shapes.Catalog.models_for(catalog, "claude") == ["anthropic/claude-opus-5"]

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
    test "copies secrets server-side and returns only the boundary metadata" do
      client =
        fake([
          {%{method: "POST", path: "/api/vaults/source/copy", body: %{name: "track"}},
           {201, [],
            %{
              data: %{
                id: "copy",
                name: "track",
                secret_count: 2,
                metadata: %{track: "t"},
                description: "snapshot"
              }
            }}}
        ])

      assert {:ok, %Shapes.Vault{id: "copy", secret_count: 2, metadata: %{"track" => "t"}}} =
               Fountain.copy_vault(client, "source", %{name: "track"})
    end

    test "missing or foreign sources are gone; invalid copies are rejected" do
      for {status, code} <- [{404, "not_found"}, {422, "secret_not_copyable"}] do
        client =
          fake([
            {%{method: "POST", path: "/api/vaults/source/copy"},
             {status, [], %{error: code, key: "EXAMPLE"}}}
          ])

        assert {:error, %Error{} = error} =
                 Fountain.copy_vault(client, "source", %{name: "track"})

        assert Error.vault_gone?(error) == (status == 404)
        assert Error.rejected?(error)
      end
    end

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

    test "environment failures never log echoed readable values" do
      client =
        fake([
          {%{method: "PUT", path: "/api/environments/e"},
           {422, [], %{error: "invalid", message: "rejected readable-private-marker"}}}
        ])

      log =
        capture_log(fn ->
          assert {:error, %Error{status: 422}} =
                   Fountain.update_environment(client, "e", %{
                     env_vars: %{"PORT" => "readable-private-marker"}
                   })
        end)

      assert log =~ "fountain 422 on PUT /api/environments/e"
      refute log =~ "readable-private-marker"
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

    test "credential sets: made by name, listed with what they hold, written and cleared by provider" do
      client =
        fake([
          {%{
             method: "POST",
             path: "/api/account/inference-credential-sets",
             body: %{name: "ravix:u1"}
           }, {201, [], %{data: %{id: "set-1", name: "ravix:u1", providers: []}}}},
          {%{method: "GET", path: "/api/account/inference-credential-sets"},
           {200, [], %{data: [%{id: "set-1", name: "ravix:u1", is_default: true, providers: []}]}}},
          {%{
             method: "PUT",
             path: "/api/account/inference-credential-sets/set-1/credentials/openai_api_key",
             body: %{value: "sk-live"}
           }, {200, [], %{data: %{provider: "openai_api_key", set: true}}}},
          {%{
             method: "DELETE",
             path: "/api/account/inference-credential-sets/set-1/credentials/anthropic_api_key"
           }, {204, [], nil}}
        ])

      assert {:ok, %{"id" => "set-1"}} = Fountain.create_credential_set(client, "ravix:u1")
      assert {:ok, [%{"is_default" => true}]} = Fountain.credential_sets(client)
      assert :ok = Fountain.put_credential(client, "set-1", :openai_api_key, "sk-live")
      assert :ok = Fountain.delete_credential(client, "set-1", :anthropic_api_key)
    end

    test "ChatGPT subscriptions: a sign-in started by name or by grant, read, cancelled, and named on a set" do
      attempts = "/api/account/chatgpt-subscriptions/attempts"

      client =
        fake([
          {%{method: "POST", path: attempts, body: %{name: "ravix:u1"}},
           {201, [], %{data: %{id: "att-1", state: "pending", user_code: "AB-CD"}}}},
          {%{method: "POST", path: attempts, body: %{grant_id: "g-1"}},
           {201, [], %{data: %{id: "att-2", state: "pending"}}}},
          {%{method: "GET", path: "#{attempts}/att-1"},
           {200, [], %{data: %{id: "att-1", state: "completed", result_grant_id: "g-1"}}}},
          {%{method: "GET", path: attempts}, {200, [], %{data: [%{id: "att-2"}]}}},
          {%{method: "DELETE", path: "#{attempts}/att-2"},
           {200, [], %{data: %{id: "att-2", state: "cancelled"}}}},
          {%{method: "GET", path: "/api/account/chatgpt-subscriptions"},
           {200, [], %{data: [%{id: "g-1", name: "ravix:u1", status: "active"}], count: 1}}},
          {%{
             method: "PATCH",
             path: "/api/account/inference-credential-sets/set-1",
             body: %{chatgpt_grant_id: "g-1"}
           }, {200, [], %{data: %{id: "set-1", chatgpt_grant: %{id: "g-1"}}}}},
          {%{
             method: "PATCH",
             path: "/api/account/inference-credential-sets/set-1",
             body: %{chatgpt_grant_id: nil}
           }, {200, [], %{data: %{id: "set-1", chatgpt_grant: nil}}}}
        ])

      assert {:ok, %{"id" => "att-1", "user_code" => "AB-CD"}} =
               Fountain.start_chatgpt_link(client, %{name: "ravix:u1"})

      assert {:ok, %{"id" => "att-2"}} = Fountain.start_chatgpt_link(client, %{grant_id: "g-1"})
      assert {:ok, %{"state" => "completed"}} = Fountain.chatgpt_link(client, "att-1")
      assert {:ok, [%{"id" => "att-2"}]} = Fountain.pending_chatgpt_links(client)
      assert {:ok, %{"state" => "cancelled"}} = Fountain.cancel_chatgpt_link(client, "att-2")
      assert {:ok, [%{"name" => "ravix:u1"}]} = Fountain.chatgpt_subscriptions(client)

      assert {:ok, %{"chatgpt_grant" => %{"id" => "g-1"}}} =
               Fountain.name_chatgpt_subscription(client, "set-1", "g-1")

      assert {:ok, %{"chatgpt_grant" => nil}} =
               Fountain.name_chatgpt_subscription(client, "set-1", nil)
    end

    test "disconnecting a subscription posts to its route and gives back the row, never a token" do
      client =
        fake([
          {%{method: "POST", path: "/api/account/chatgpt-subscriptions/g-1/disconnect"},
           {200, [], %{data: %{id: "g-1", name: "ravix:u1", status: "disconnected"}}}}
        ])

      assert {:ok, %{"id" => "g-1", "status" => "disconnected"}} =
               Fountain.disconnect_chatgpt_subscription(client, "g-1")
    end

    test "deleting a subscription frees the ChatGPT account; renaming changes only whose it is" do
      client =
        fake([
          {%{method: "DELETE", path: "/api/account/chatgpt-subscriptions/g-1"}, {204, [], nil}},
          {%{method: "PATCH", path: "/api/account/chatgpt-subscriptions/g-2", body: %{name: "x"}},
           {200, [], %{data: %{id: "g-2", name: "x", status: "active"}}}}
        ])

      assert :ok = Fountain.delete_chatgpt_subscription(client, "g-1")

      assert {:ok, %{"id" => "g-2", "name" => "x"}} =
               Fountain.rename_chatgpt_subscription(client, "g-2", "x")

      # A grant is renamed, never un-named: a set names a grant by id, so a
      # nameless grant is one nothing here can find again.
      assert_raise FunctionClauseError, fn ->
        Fountain.rename_chatgpt_subscription(fake([]), "g-2", nil)
      end
    end

    test "a subscription id from outside cannot walk out of its route" do
      client =
        fake([
          {%{method: "DELETE", path: "/api/account/chatgpt-subscriptions/..%2F..%2Fagents"},
           {404, [], %{error: "not_found"}}}
        ])

      assert {:error, %Ravix.Fountain.Error{status: 404}} =
               Fountain.delete_chatgpt_subscription(client, "../../agents")
    end

    test "a provider Fountain has no slot for never becomes a path" do
      assert_raise FunctionClauseError, fn ->
        Fountain.put_credential(fake([]), "set-1", :"../../agents", "v")
      end
    end

    test "a refused credential logs the path and the status, never the value or the reply" do
      path = "/api/account/inference-credential-sets/set-1/credentials/claude_code_oauth_token"

      client =
        fake([
          {%{method: "PUT", path: path},
           {422, [],
            %{error: "the provider rejected sk-ant-oat01-echoed (HTTP 401)", reason: "invalid"}}}
        ])

      log =
        capture_log(fn ->
          assert {:error, %Error{status: 422}} =
                   Fountain.put_credential(
                     client,
                     "set-1",
                     :claude_code_oauth_token,
                     "sk-ant-oat01-echoed"
                   )
        end)

      assert log =~ "fountain 422 on PUT #{path}"
      # The reply to a request whose body was a credential is not logged
      # either: it is where an API would echo one.
      refute log =~ "sk-ant-oat01-echoed"
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

      assert {:ok, [%Conversation{id: "c1", sandbox_id: "sb-1", status: :idle}]} =
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

      assert {:ok, %Conversation{status: :running, sprite_name: "sp-1"}} =
               Fountain.get_conversation(client, "c1")
    end
  end

  describe "create_conversation/2" do
    test "guest attach sends the other agent and complete identity; provider refusals survive" do
      body = %{
        agent_id: "guest",
        environment_id: "env",
        vault_id: "vault",
        sandbox_id: "box",
        channel_id: "ch",
        fresh: true
      }

      client =
        fake([
          {%{method: "POST", path: "/api/conversations", body: body},
           {200, [], %{data: %{id: "guest-thread", sandbox_id: "box", status: "idle"}}}},
          {%{method: "POST", path: "/api/conversations", body: body},
           {422, [], %{error: "sandbox_runtime_mismatch"}}},
          {%{method: "POST", path: "/api/conversations", body: body},
           {409, [], %{error: "sandbox_at_capacity"}}}
        ])

      guest =
        launch(agent_id: "guest", environment_id: "env", vault_id: "vault", sandbox_id: "box")

      assert {:ok, %Conversation{id: "guest-thread", sandbox_id: "box"}} =
               Fountain.create_conversation(client, guest)

      capture_log(fn ->
        assert {:error, %Error{code: "sandbox_runtime_mismatch"}} =
                 Fountain.create_conversation(client, guest)

        assert {:error, error} = Fountain.create_conversation(client, guest)
        assert Error.busy?(error)
      end)
    end

    test "provisioning: the whole identity, persistent mode, the opening prompt, fresh" do
      expected = %{
        agent_id: "agent-1",
        environment_id: "env-1",
        vault_id: "vault-1",
        sandbox_mode: "persistent",
        prompt: "Open the track.",
        channel_id: "ravix:p1:fix-the-build:1",
        fresh: true
      }

      client =
        fake([
          {%{method: "POST", path: "/api/conversations", body: expected},
           {201, [], %{data: %{id: "c1", status: "pending"}}}}
        ])

      assert {:ok, %Conversation{id: "c1", status: :pending}} =
               Fountain.create_conversation(
                 client,
                 launch(
                   agent_id: "agent-1",
                   environment_id: "env-1",
                   vault_id: "vault-1",
                   channel_id: "ravix:p1:fix-the-build:1",
                   prompt: "Open the track."
                 )
               )
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

      assert {:ok, %Conversation{id: "c2", status: :other}} =
               Fountain.create_conversation(
                 client,
                 launch(
                   agent_id: "agent-1",
                   environment_id: "env-1",
                   sandbox_id: "sb-1",
                   channel_id: "ravix:p1:next:1"
                 )
               )
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
                 Fountain.create_conversation(
                   client,
                   launch(agent_id: "agent-1", channel_id: "ch", sandbox_id: "sb-1")
                 )

        assert %{status: 409, code: "identity_mismatch"} = Error.as_http(error, "open this track")
      end)
    end
  end

  describe "prompt/5, interrupt/2, terminate/2, turns/2" do
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

    test "prompt names the submission when asked to, and not otherwise" do
      client =
        fake([
          {%{
             method: "POST",
             path: "/api/conversations/c1/prompts",
             body: %{prompt: "hello", client_request_id: "row-1234567890abcdef"}
           }, {202, [], %{data: %{ok: true}}}},
          {%{method: "POST", path: "/api/conversations/c1/prompts", body: %{prompt: "bare"}},
           {202, [], %{data: %{ok: true}}}}
        ])

      assert :ok =
               Fountain.prompt(client, "c1", "hello", [],
                 client_request_id: "row-1234567890abcdef"
               )

      assert :ok = Fountain.prompt(client, "c1", "bare", [], client_request_id: nil)
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
                  inserted_at: "2026-09-09T00:00:00Z",
                  client_request_id: "row-1"
                },
                %{id: "t2", prompt: "typed elsewhere", status: "done"}
              ]
            }}}
        ])

      assert :ok = Fountain.interrupt(client, "c1")
      assert :ok = Fountain.terminate(client, "c1")

      assert {:ok,
              [
                %Turn{
                  id: "t1",
                  prompt: "hi",
                  origin: "api",
                  status: "done",
                  client_request_id: "row-1"
                },
                %Turn{id: "t2", client_request_id: nil}
              ]} = Fountain.turns(client, "c1")
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

  describe "wake/2" do
    test "awake and waking are the two answers, and nothing is sent with them" do
      client =
        fake([
          {%{method: "POST", path: "/api/conversations/c%2F1/wake", body: nil},
           {200, [], %{status: "awake"}}},
          {%{method: "POST", path: "/api/conversations/c%2F1/wake", body: nil},
           {200, [], %{status: "waking"}}}
        ])

      assert {:ok, :awake} = Fountain.wake(client, "c/1")
      assert {:ok, :waking} = Fountain.wake(client, "c/1")
    end

    test "a status Fountain does not document is an error, not an atom" do
      client =
        fake([
          {%{method: "POST", path: "/api/conversations/c1/wake"}, {200, [], %{status: "dozing"}}},
          {%{method: "POST", path: "/api/conversations/c1/wake"}, {200, [], %{}}}
        ])

      capture_log(fn ->
        for _ <- 1..2 do
          assert {:error, %Error{status: 502, code: "wake_status_unknown"} = error} =
                   Fountain.wake(client, "c1")

          assert Error.as_http(error, "wake").status == 502
        end
      end)
    end

    for {status, body, code, words} <- [
          {402, %{error: "insufficient_credits", upgrade_url: "/account/billing"},
           "insufficient_credits", "out of credits"},
          {409, %{error: "sandbox_reset_pending", message: "torn down"}, "sandbox_reset_pending",
           "torn down or reset"},
          {410, %{error: "conversation_terminated"}, "conversation_terminated", "has ended"},
          {503, %{error: "sandbox_unavailable", message: "send it again shortly"},
           "sandbox_unavailable", "not available right now"},
          {503, %{error: "fleet_full", message: "Every sandbox slot is in use"}, "fleet_full",
           "not available right now"}
        ] do
      @tag status: status, body: body, code: code, words: words
      test "#{status} #{code} is refused with the copy a prompt's refusal uses", ctx do
        client =
          fake([
            {%{method: "POST", path: "/api/conversations/c1/wake"}, {ctx.status, [], ctx.body}}
          ])

        capture_log(fn ->
          assert {:error, %Error{status: status, code: code} = error} =
                   Fountain.wake(client, "c1")

          assert {status, code} == {ctx.status, ctx.code}
          assert Error.as_http(error, "wake").message =~ ctx.words
        end)
      end
    end

    test "a 404 is a not-found like any other, whether the conversation or the route is missing" do
      client =
        fake([
          {%{method: "POST", path: "/api/conversations/c1/wake"},
           {404, [], %{error: "not_found"}}},
          {%{method: "POST", path: "/api/conversations/c1/wake"},
           {404, [], %{errors: %{detail: "Not Found"}}}}
        ])

      capture_log(fn ->
        for _ <- 1..2 do
          assert {:error, %Error{status: 404, kind: :not_found} = missing} =
                   Fountain.wake(client, "c1")

          assert Error.as_http(missing, "wake").status == 404
        end
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

    test "asking for prompts asks for blocks too, because Fountain fills one only with the other" do
      client =
        fake([
          {%{
             method: "GET",
             path: "/api/conversations/c1/events",
             query: %{limit: "1", after: "6", blocks: "true", prompts: "true"}
           }, {200, [], %{data: [%{id: 7}], meta: %{has_more: false}}}}
        ])

      assert {:ok, %{events: [%{"id" => 7}]}} =
               Fountain.events_page(client, "c1", after: 6, limit: 1, prompts: true)
    end

    test "newest first: before, whole turns, and the page window as a struct" do
      window = %{order: "desc", oldest_cursor: 40, newest_cursor: 97, turn_split: true}

      client =
        fake([
          {%{
             method: "GET",
             path: "/api/conversations/c1/events",
             query: %{
               limit: "300",
               before: "120",
               order: "desc",
               whole_turns: "true",
               blocks: "true",
               prompts: "true"
             }
           },
           {200, [],
            %{
              data: [%{id: 97}, %{id: 40}],
              meta: %{limit: 300, has_more: true, next_cursor: 40},
              page: window
            }}},
          # whole_turns is refused by Fountain without desc, so it is not sent.
          {%{method: "GET", path: "/api/conversations/c1/events", query: %{limit: "1000"}},
           {200, [],
            %{data: [], meta: %{has_more: false, next_cursor: nil}, page: %{order: "asc"}}}}
        ])

      assert {:ok,
              %{
                events: [%{"id" => 97}, %{"id" => 40}],
                has_more: true,
                next_cursor: 40,
                window: %Shapes.EventWindow{
                  order: :desc,
                  oldest_cursor: 40,
                  newest_cursor: 97,
                  turn_split: true
                }
              }} =
               Fountain.events_page(client, "c1",
                 order: :desc,
                 before: 120,
                 whole_turns: true,
                 limit: 300,
                 prompts: true
               )

      assert {:ok,
              %{
                events: [],
                next_cursor: nil,
                window: %Shapes.EventWindow{order: :asc, oldest_cursor: nil, turn_split: false}
              }} = Fountain.events_page(client, "c1", whole_turns: true)
    end

    test "a Fountain without the page object reports no window" do
      client =
        fake([
          {%{method: "GET", path: "/api/conversations/c1/events"},
           {200, [], %{data: [%{id: 1}], meta: %{has_more: false}, page: %{order: "sideways"}}}},
          {%{method: "GET", path: "/api/conversations/c1/events"},
           {200, [], %{data: [%{id: 1}], meta: %{has_more: false}}}}
        ])

      assert {:ok, %{window: nil}} = Fountain.events_page(client, "c1", order: :desc)
      assert {:ok, %{window: nil}} = Fountain.events_page(client, "c1", order: :desc)
    end

    test "a forward read continues from a first page already in hand, and only reads forward" do
      client =
        fake([
          {%{
             method: "GET",
             path: "/api/conversations/c1/events",
             query: %{limit: "1000", after: "5", prompts: "true", blocks: "true"}
           }, {200, [], %{data: [%{id: 5}, %{id: 9}], meta: %{has_more: false}}}}
        ])

      first = %{events: [%{"id" => 5}, %{"id" => 2}], has_more: true, next_cursor: 5}

      assert {:ok, [%{"id" => 2}, %{"id" => 5}, %{"id" => 9}]} =
               Fountain.events(client, "c1",
                 from: first,
                 prompts: true,
                 order: :desc,
                 whole_turns: true,
                 before: 3
               )

      assert {:ok, [%{"id" => 2}]} =
               Fountain.events(client, "c1",
                 from: %{first | has_more: false, events: [%{"id" => 2}]}
               )
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
               message:
                 "Could not reach the machine service to watch this track. Try again in a moment."
             } =
               Error.as_http(error, "watch this track")
    end
  end

  # ── reading the machine ─────────────────────────────────────────────────

  describe "sandboxes" do
    test "list filters statuses and preserves reconciliation identity without inventing status" do
      client =
        fake([
          {%{method: "GET", path: "/api/sandboxes", query: %{status: "ready,parked"}},
           {200, [],
            %{
              data: [
                %{
                  id: "s1",
                  status: "parked",
                  agent_id: "home",
                  environment_id: "env",
                  vault_id: "track-vault",
                  user_id: "owner"
                },
                %{id: "s2", status: 42}
              ]
            }}}
        ])

      assert {:ok, [first, second]} = Fountain.sandboxes(client, status: ["ready", "parked"])

      assert %Sandbox{
               id: "s1",
               status: "parked",
               agent_id: "home",
               environment_id: "env",
               vault_id: "track-vault",
               user_id: "owner"
             } = first

      assert second.status == nil
    end

    test "reset escapes ids, accepts deletion and treats only explicit absence as already gone" do
      client =
        fake([
          {%{method: "DELETE", path: "/api/sandboxes/s%2F1"}, {204, [], ""}},
          {%{method: "DELETE", path: "/api/sandboxes/s1"},
           {404, [], %{error: "sandbox_not_found"}}},
          {%{method: "DELETE", path: "/api/sandboxes/gone"}, {410, [], %{error: "sandbox_gone"}}},
          {%{method: "DELETE", path: "/api/sandboxes/unsupported"},
           {404, [], %{error: "not_found"}}}
        ])

      capture_log(fn ->
        assert :ok = Fountain.reset_sandbox(client, "s/1")
        assert :ok = Fountain.reset_sandbox(client, "s1")
        assert :ok = Fountain.reset_sandbox(client, "gone")

        assert {:error, %Error{status: 404} = error} =
                 Fountain.reset_sandbox(client, "unsupported")

        refute Error.sandbox_gone?(error)
      end)
    end

    test "a reset acknowledgement still needs a status read to confirm completion" do
      client =
        fake([
          {%{method: "DELETE", path: "/api/sandboxes/s1"},
           {202, [], %{data: %{status: "deleting"}}}},
          {%{method: "GET", path: "/api/sandboxes/s1"},
           {200, [], %{data: %{id: "s1", status: "deleting"}}}},
          {%{method: "GET", path: "/api/sandboxes/s1"},
           {200, [], %{data: %{id: "s1", status: "terminated"}}}}
        ])

      assert :ok = Fountain.reset_sandbox(client, "s1")
      assert {:ok, %Sandbox{status: "deleting"}} = Fountain.sandbox(client, "s1")

      assert {:ok, %Sandbox{status: "terminated"}} = Fountain.sandbox(client, "s1")
    end

    test "lost create and reset acknowledgements stay unknown and are never automatically retried" do
      for response <- [{:error, :timeout}, {408, [], %{}}, {503, [], %{error: "unavailable"}}] do
        client =
          fake([
            {%{method: "POST", path: "/api/conversations"}, response},
            {%{method: "DELETE", path: "/api/sandboxes/s1"}, response}
          ])

        capture_log(fn ->
          assert {:error, create_error} =
                   Fountain.create_conversation(client, launch(prompt: "open"))

          assert Error.unknown_outcome?(create_error)
          assert {:error, reset_error} = Fountain.reset_sandbox(client, "s1")
          assert Error.unknown_outcome?(reset_error)
        end)

        assert length(FakeTransport.calls(client)) == 2
      end

      refute Error.unknown_outcome?(%Error{status: 422, code: "sandbox_runtime_mismatch"})
      refute Error.unknown_outcome?(%Error{status: 409, code: "sandbox_at_capacity"})
    end

    test "unconfigured sandbox operations never send a request" do
      client = Client.new("https://fountain.example", nil)
      assert {:error, {:unconfigured, :fountain}} = Fountain.sandboxes(client)
      assert {:error, {:unconfigured, :fountain}} = Fountain.reset_sandbox(client, "s1")
    end

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

      assert {:ok, %Sandbox{sprite_name: "sp-1"}} = Fountain.sandbox(client, "sb-1")

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
    test "suspension is identified by code and structured status, never message text" do
      suspended =
        Error.from_sdk(%Elixir.Fountain.Error{
          status: 409,
          code: "sandbox_not_ready",
          body: %{"status" => "suspended", "message" => "different wording"}
        })

      assert Error.sandbox_suspended?(suspended)
      refute Error.sandbox_suspended?(%{suspended | status: 503})
      refute Error.sandbox_suspended?(%{suspended | code: "other_conflict"})
      refute Error.sandbox_suspended?(%{suspended | sandbox_status: "failed"})

      refute Error.sandbox_suspended?(%{
               suspended
               | sandbox_status: nil,
                 message: "the sandbox is suspended; files are read from a ready one only"
             })
    end

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

    test "public failures explain capacity and never echo bare provider codes" do
      for action <- ["add a thread", "retry", "interrupt"] do
        response = Error.as_http(%Error{status: 409, code: "sandbox_at_capacity"}, action)
        assert response.message == "The machine is busy with other turns. Try again in a moment."
      end

      for code <- [
            "adapter_crashed",
            "session_gone",
            "inference_credential_unusable",
            "unknown_code"
          ] do
        response = Error.as_http(%Error{status: 422, code: code, message: code}, "send")
        refute response.message =~ code
        refute response.message =~ "Fountain"
        assert response.message =~ "."
      end
    end

    test "as_http mirrors asHttpError" do
      # A deployment with no Fountain is not a Fountain failure: that is
      # `{:unconfigured, :fountain}`, sentenced once in `RavixWeb.Error`.
      assert %{status: 503, code: "no_fountain"} =
               Map.from_struct(RavixWeb.Error.from({:unconfigured, :fountain}))

      assert %{status: 502, code: "fountain_rejected"} = Error.as_http(%Error{status: 401}, "x")

      assert %{status: 502, code: "fountain_rejected"} =
               Error.as_http(%Error{status: 403, code: "forbidden"}, "x")

      assert %{status: 409, code: "machine_busy"} =
               Error.as_http(%Error{status: 409, code: "sandbox_at_capacity"}, "x")

      assert %{status: 409, code: "identity_mismatch"} =
               Error.as_http(%Error{status: 409, code: "sandbox_identity_mismatch"}, "x")

      assert %{
               status: 502,
               code: "fountain_error",
               message:
                 "The machine service could not complete the request. Try again in a moment."
             } =
               Error.as_http(%Error{status: 500, message: "boom"}, "x")

      assert %{
               status: 404,
               code: "not_found",
               message:
                 "The machine service could not complete the request. Try again in a moment."
             } =
               Error.as_http(%Error{status: 404, code: "not_found", message: "gone"}, "x")

      assert %{
               status: 502,
               code: "fountain_unreachable",
               message:
                 "Could not reach the machine service to build this project. Try again in a moment."
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
