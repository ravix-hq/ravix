defmodule Ravix.Accounts.ThreadPreferenceTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.{Inference, ThreadPreference}
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Fountain.Shapes.Catalog

  @catalog %Catalog{
    runtimes: ["claude", "codex"],
    models: %{
      "claude" => ["sonnet", "opus"],
      "codex" => ["gpt"]
    }
  }

  test "empty preferences follow the latest held connection, including ChatGPT and token timestamps" do
    user = insert_user(agent: :claude, credential_set_id: "set")

    {:ok, user} =
      Ravix.Accounts.save_setup(user, %{
        credential_connected_at: %{
          "claude:subscription" => "2026-09-01T00:00:00.000000Z",
          "codex:api_key" => "2026-09-02T00:00:00.000000Z",
          "codex:subscription" => "2026-09-03T00:00:00.000000Z"
        }
      })

    stub(Inference, :cached_held, fn _ ->
      {:ok, [{:claude, :subscription}, {:codex, :api_key}, {:codex, :subscription}]}
    end)

    assert {:ok, %{runtime: "codex", model: "gpt"}} = ThreadPreference.get(user, @catalog)

    {:ok, user} =
      Ravix.Accounts.save_setup(user, %{
        credential_connected_at:
          Map.put(
            user.credential_connected_at,
            "claude:subscription",
            "2026-09-04T00:00:00.000000Z"
          )
      })

    assert {:ok, %{runtime: "claude", model: "sonnet"}} = ThreadPreference.get(user, @catalog)
    assert {:ok, _} = ThreadPreference.put(user, "claude", "opus", @catalog)
    assert {:ok, %{runtime: "claude", model: "opus"}} = ThreadPreference.get(user, @catalog)
  end

  test "only held credentials count and empty accounts have no preference" do
    user = insert_user()
    assert {:ok, nil} = ThreadPreference.get(user, @catalog)
    user = insert_user(agent: :codex, credential_set_id: "set")
    stub(Inference, :cached_held, fn _ -> {:ok, []} end)
    assert {:ok, nil} = ThreadPreference.get(user, @catalog)
    stub(Inference, :cached_held, fn _ -> {:ok, [{:claude, :api_key}]} end)
    assert {:ok, %{runtime: "claude", model: "sonnet"}} = ThreadPreference.get(user, @catalog)
  end

  test "invalid runtimes/models are refused, and an explicit preference changes only its person" do
    user = insert_user()
    other = insert_user()
    assert {:error, _} = ThreadPreference.put(user, "unknown", "opus", @catalog)
    assert {:error, _} = ThreadPreference.put(user, "codex", "opus", @catalog)
    assert {:ok, _} = ThreadPreference.put(user, "claude", "opus", @catalog)
    assert {:ok, nil} = ThreadPreference.get(other, @catalog)
    assert {:ok, %{model: "opus"}} = ThreadPreference.get(user, @catalog)
  end

  test "account setting refuses disconnected agents and persists a validated choice" do
    user = insert_user()
    stub(Inference, :usable?, fn _, _, _ -> {:ok, false} end)

    assert {:error, {:unprocessable, "agent_not_connected", _}} =
             ThreadPreference.save(user, "codex", "gpt")

    stub(Inference, :usable?, fn _, _, _ -> {:ok, true} end)

    stub(Ravix.Fountain, :client, fn -> FakeTransport.client([], verify: false) end)

    stub(Ravix.MachineCache, :catalog, fn _ -> {:ok, @catalog} end)

    assert {:ok, %{preferred_runtime: :codex, preferred_model: "gpt"}} =
             ThreadPreference.save(user, "codex", "gpt")
  end
end
