defmodule Ravix.Accounts.InferenceAvailabilityTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.Inference
  alias Ravix.Accounts.Inference.Cache
  alias Ravix.Fountain.{Client, Error, FakeTransport}

  @sets "/api/account/inference-credential-sets"

  defp fountain(script) do
    client = FakeTransport.client(script)
    stub(Ravix.Fountain, :client, fn -> client end)
    client
  end

  defp listed(providers, grant \\ nil) do
    {%{method: "GET", path: @sets},
     {200, [], %{data: [%{id: "mine", providers: providers, chatgpt_grant_id: grant}]}}}
  end

  test "availability follows the real set, not the saved agent or kind" do
    for {providers, grant, agents} <- [
          {[], nil, []},
          {["claude_code_oauth_token"], nil, [:claude]},
          {[], "grant", [:codex]},
          {["claude_code_oauth_token"], "grant", [:claude, :codex]},
          {["anthropic_api_key", "openai_api_key"], nil, [:claude, :codex]},
          {["gemini_api_key"], nil, []}
        ] do
      user = insert_user(credential_set_id: "mine", agent: :codex, credential_kind: :api_key)
      client = fountain([listed(providers, grant)])
      assert Inference.usable_agents(user) == {:ok, agents}
      assert Inference.usable?(user, :claude) == {:ok, :claude in agents}
      assert Inference.usable?(user, "codex") == {:ok, :codex in agents}
      assert Inference.usable?(user, "claude-code") == {:ok, false}
      assert length(FakeTransport.calls(client)) == 1
    end
  end

  test "no set and a missing set hold nothing" do
    client = fountain([])
    assert Inference.usable_agents(insert_user()) == {:ok, []}
    assert FakeTransport.calls(client) == []

    fountain([
      {%{method: "GET", path: @sets},
       {200, [], %{data: [%{id: "other", providers: ["openai_api_key"]}]}}}
    ])

    assert Inference.usable_agents(insert_user(credential_set_id: "mine")) == {:ok, []}
  end

  test "first connect discovers availability after creating the person's set" do
    user = insert_user()

    fountain([
      {%{method: "GET", path: @sets}, {200, [], %{data: [%{id: "house", is_default: true}]}}},
      {%{method: "POST", path: @sets, body: %{name: "ravix:#{user.id}"}},
       {201, [], %{data: %{id: "mine"}}}},
      {%{method: "PUT", path: "#{@sets}/mine/credentials/openai_api_key"},
       {200, [], %{data: %{set: true}}}},
      listed(["openai_api_key"])
    ])

    assert user.credential_set_id == nil
    assert Inference.usable_agents(user) == {:ok, []}

    assert {:ok, connected} =
             Inference.connect(user, %{agent: :codex, kind: :api_key, value: "test-key"})

    assert connected.credential_set_id == "mine"
    assert Inference.usable_agents(connected) == {:ok, [:codex]}
  end

  test "provider errors are returned and not remembered" do
    user = insert_user(credential_set_id: "mine", agent: :claude, credential_kind: :subscription)

    fountain([
      {%{method: "GET", path: @sets}, {503, [], %{error: "down"}}},
      listed(["openai_api_key"])
    ])

    assert {:error, %Error{status: 503}} = Inference.usable?(user, :claude)
    assert Inference.usable_agents(user) == {:ok, [:codex]}
  end

  test "unconfigured Fountain is an error" do
    stub(Ravix.Fountain, :client, fn -> Client.new("https://fountain.test", nil) end)

    assert Inference.usable_agents(insert_user(credential_set_id: "mine")) ==
             {:error, {:unconfigured, :fountain}}
  end

  test "cache expires after five seconds and is isolated by person" do
    user = insert_user(credential_set_id: "mine")
    other = insert_user(credential_set_id: "mine")
    fountain([listed([]), listed(["openai_api_key"]), listed(["anthropic_api_key"])])
    Ravix.Clock.freeze(1_000)
    assert Inference.usable_agents(user) == {:ok, []}
    assert Inference.usable_agents(other) == {:ok, [:codex]}
    Ravix.Clock.freeze(5_999)
    assert Inference.usable_agents(user) == {:ok, []}
    Ravix.Clock.freeze(6_000)
    assert Inference.usable_agents(user) == {:ok, [:claude]}
  end

  test "fresh reads bypass a populated cache" do
    user = insert_user(credential_set_id: "mine")
    fountain([listed(["openai_api_key"]), listed([])])
    assert Inference.usable_agents(user) == {:ok, [:codex]}
    assert Inference.usable?(user, "codex", fresh: true) == {:ok, false}
  end

  test "connect and disconnect invalidate even when the selected agent differs" do
    user = insert_user(credential_set_id: "mine", agent: :claude, credential_kind: :subscription)

    fountain([
      listed(["claude_code_oauth_token"]),
      {%{method: "PUT", path: "#{@sets}/mine/credentials/openai_api_key"},
       {200, [], %{data: %{set: true}}}},
      listed(["claude_code_oauth_token", "openai_api_key"]),
      {%{method: "DELETE", path: "#{@sets}/mine/credentials/claude_code_oauth_token"},
       {204, [], nil}},
      listed(["openai_api_key"])
    ])

    assert Inference.usable_agents(user) == {:ok, [:claude]}

    assert {:ok, user} =
             Inference.connect(user, %{agent: :codex, kind: :api_key, value: "test-key"})

    assert Inference.usable_agents(user) == {:ok, [:claude, :codex]}
    assert {:ok, user} = Inference.disconnect(user, :claude, :subscription)
    assert Inference.usable_agents(user) == {:ok, [:codex]}
  end

  test "completed linking invalidates the cache" do
    user = insert_user(credential_set_id: "mine")

    fountain([
      listed([]),
      {%{method: "GET", path: "/api/account/chatgpt-subscriptions/attempts/attempt"},
       {200, [], %{data: %{state: "completed", result_grant_id: "grant"}}}},
      {%{method: "PATCH", path: "#{@sets}/mine"}, {200, [], %{data: %{id: "mine"}}}},
      listed([], "grant")
    ])

    assert Inference.usable_agents(user) == {:ok, []}

    assert {:ok, user} =
             Inference.poll_link(user, %Inference.Link{attempt_id: "attempt", set_id: "mine"})

    assert Inference.usable_agents(user) == {:ok, [:codex]}
  end

  test "partial connection failure also invalidates a possibly changed set" do
    user = insert_user(credential_set_id: "mine", agent: :claude, credential_kind: :subscription)

    fountain([
      listed(["claude_code_oauth_token"]),
      {%{method: "PUT", path: "#{@sets}/mine/credentials/anthropic_api_key"},
       {200, [], %{data: %{set: true}}}},
      {%{method: "DELETE", path: "#{@sets}/mine/credentials/claude_code_oauth_token"},
       {503, [], %{error: "down"}}},
      listed(["claude_code_oauth_token", "anthropic_api_key"])
    ])

    assert Inference.usable_agents(user) == {:ok, [:claude]}

    assert {:error, %Error{status: 503}} =
             Inference.connect(user, %{agent: :claude, kind: :api_key, value: "test-key"})

    assert Inference.usable_agents(user) == {:ok, [:claude]}
  end

  test "invalidating concurrent readers answers all waiters and rejects stale writes" do
    user = insert_user(credential_set_id: "mine")
    parent = self()

    load = fn ->
      send(parent, {:loading, self()})

      receive do
        :finish -> {:ok, [{:claude, :subscription}]}
      end
    end

    readers = for _ <- 1..4, do: Task.async(fn -> Cache.fetch(user, load) end)
    assert_receive {:loading, loader}, 1_000
    await_waiters({user.id, "mine"}, 4)
    :ok = Cache.invalidate(user)
    # A second invalidation while the disowned load still exists must be safe.
    :ok = Cache.invalidate(user)
    :sys.get_state(Cache)
    assert Cache.fetch(user, fn -> {:ok, [{:codex, :api_key}]} end) == {:ok, [{:codex, :api_key}]}
    send(loader, :finish)
    for reader <- readers, do: assert(Task.await(reader) == {:ok, [{:claude, :subscription}]})

    assert Cache.fetch(user, fn -> flunk("stale result replaced the new generation") end) ==
             {:ok, [{:codex, :api_key}]}
  end

  test "broadcast invalidation removes a locally held answer" do
    user = insert_user(credential_set_id: "mine")
    assert Cache.fetch(user, fn -> {:ok, []} end) == {:ok, []}
    send(Cache, {:invalidate, user.id})
    # A server call is a barrier after the preceding message from this process.
    :sys.get_state(Cache)
    assert Cache.fetch(user, fn -> {:ok, [{:codex, :api_key}]} end) == {:ok, [{:codex, :api_key}]}
  end

  defp await_waiters(key, count) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_waiters(key, count, deadline)
  end

  defp await_waiters(key, count, deadline) do
    case :sys.get_state(Cache.Reads).loads[key] do
      %{waiters: waiters} when length(waiters) == count ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "readers never joined the load"
        await_waiters(key, count, deadline)
    end
  end
end
