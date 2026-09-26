defmodule Ravix.Accounts.InferenceCacheOutageTest do
  use Ravix.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Ravix.Accounts.Inference
  alias Ravix.Accounts.Inference.Cache
  alias Ravix.Fountain.FakeTransport

  @sets "/api/account/inference-credential-sets"

  for child <- [Cache, Cache.Reads] do
    test "successful credential writes survive #{inspect(child)} being down" do
      child = unquote(child)
      :ok = Supervisor.terminate_child(Ravix.Supervisor, child)
      on_exit(fn -> Supervisor.restart_child(Ravix.Supervisor, child) end)
      assert Process.whereis(child) == nil

      user = insert_user(credential_set_id: "mine")

      client =
        FakeTransport.client([
          {%{method: "PUT", path: "#{@sets}/mine/credentials/openai_api_key"},
           {200, [], %{data: %{set: true}}}},
          {%{method: "DELETE", path: "#{@sets}/mine/credentials/openai_api_key"}, {204, [], nil}},
          {%{method: "GET", path: "/api/account/chatgpt-subscriptions/attempts/attempt"},
           {200, [], %{data: %{state: "completed", result_grant_id: "grant"}}}},
          {%{method: "PATCH", path: "#{@sets}/mine"}, {200, [], %{data: %{id: "mine"}}}}
        ])

      stub(Ravix.Fountain, :client, fn -> client end)

      capture_log(fn ->
        assert {:ok, connected} =
                 Inference.connect(user, %{agent: :codex, kind: :api_key, value: "test-key"})

        assert connected.credential_kind == :api_key
        assert {:ok, disconnected} = Inference.disconnect(connected, :codex, :api_key)
        assert disconnected.credential_kind == nil

        assert {:ok, linked} =
                 Inference.poll_link(disconnected, %Inference.Link{
                   attempt_id: "attempt",
                   set_id: "mine"
                 })

        assert linked.credential_kind == :subscription
        if Process.whereis(Cache), do: :sys.get_state(Cache)
      end)
    end
  end
end
