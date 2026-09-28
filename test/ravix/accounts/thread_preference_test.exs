defmodule Ravix.Accounts.ThreadPreferenceTest do
  use Ravix.DataCase, async: true
  use Mimic

  alias Ravix.Accounts.{Inference, ThreadPreference}
  alias Ravix.Fountain.FakeTransport
  alias Ravix.Fountain.Shapes.Catalog
  alias Ravix.Projects.Machine

  @catalog %Catalog{
    runtimes: ["claude", "codex"],
    models: %{
      "claude" => ["anthropic/claude-sonnet-5", "anthropic/claude-opus-5-5"],
      "codex" => ["openai/gpt-6-astra"]
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

    assert {:ok, %{runtime: "codex", model: "openai/gpt-6-astra"}} =
             ThreadPreference.get(user, @catalog)

    {:ok, user} =
      Ravix.Accounts.save_setup(user, %{
        credential_connected_at:
          Map.put(
            user.credential_connected_at,
            "claude:subscription",
            "2026-09-04T00:00:00.000000Z"
          )
      })

    assert {:ok, %{runtime: "claude", model: "anthropic/claude-opus-5-5"}} =
             ThreadPreference.get(user, @catalog)

    assert {:ok, _} = ThreadPreference.put(user, "claude", "anthropic/claude-opus-5-5", @catalog)

    assert {:ok, %{runtime: "claude", model: "anthropic/claude-opus-5-5"}} =
             ThreadPreference.get(user, @catalog)
  end

  test "subscription defaults and removed saved models avoid Fable even when it is first" do
    catalog = %Catalog{
      runtimes: ["claude", "codex"],
      models: %{
        "claude" => [
          "anthropic/claude-fable-5-1",
          "anthropic/claude-opus-5-5",
          "anthropic/claude-opus-5"
        ],
        "codex" => ["openai/gpt-6-astra"]
      }
    }

    user = insert_user(agent: :claude, credential_set_id: "set")
    stub(Inference, :cached_held, fn _ -> {:ok, [{:claude, :subscription}]} end)
    assert {:ok, %{model: "anthropic/claude-opus-5"}} = ThreadPreference.get(user, catalog)

    assert Machine.pick_runtime(catalog, "claude").model ==
             "anthropic/claude-opus-5"

    assert {:ok, _} = ThreadPreference.put(user, "claude", "anthropic/claude-opus-5-5", catalog)

    removed = %{
      catalog
      | models:
          Map.put(catalog.models, "claude", [
            "anthropic/claude-fable-5-1",
            "anthropic/claude-opus-5"
          ])
    }

    assert {:ok, %{model: "anthropic/claude-opus-5"}} = ThreadPreference.get(user, removed)

    newer = %{
      catalog
      | models:
          Map.put(catalog.models, "claude", [
            "anthropic/claude-fable-5-1",
            "anthropic/claude-opus-5-5"
          ])
    }

    assert {:ok, _} = ThreadPreference.clear(user)
    assert {:ok, %{model: "anthropic/claude-opus-5-5"}} = ThreadPreference.get(user, newer)
  end

  test "only held credentials count and empty accounts have no preference" do
    user = insert_user()
    assert {:ok, nil} = ThreadPreference.get(user, @catalog)
    user = insert_user(agent: :codex, credential_set_id: "set")
    stub(Inference, :cached_held, fn _ -> {:ok, []} end)
    assert {:ok, nil} = ThreadPreference.get(user, @catalog)
    stub(Inference, :cached_held, fn _ -> {:ok, [{:claude, :api_key}]} end)

    assert {:ok, %{runtime: "claude", model: "anthropic/claude-opus-5-5"}} =
             ThreadPreference.get(user, @catalog)
  end

  test "invalid runtimes/models are refused, and an explicit preference changes only its person" do
    user = insert_user()
    other = insert_user()

    assert {:error, _} =
             ThreadPreference.put(user, "unknown", "anthropic/claude-opus-5-5", @catalog)

    assert {:error, _} =
             ThreadPreference.put(user, "codex", "anthropic/claude-opus-5-5", @catalog)

    assert {:ok, _} = ThreadPreference.put(user, "claude", "anthropic/claude-opus-5-5", @catalog)
    assert {:ok, nil} = ThreadPreference.get(other, @catalog)
    assert {:ok, %{model: "anthropic/claude-opus-5-5"}} = ThreadPreference.get(user, @catalog)
  end

  test "account setting refuses disconnected agents and persists a validated choice" do
    user = insert_user()
    stub(Inference, :usable?, fn _, _, _ -> {:ok, false} end)

    assert {:error, {:unprocessable, "agent_not_connected", _}} =
             ThreadPreference.save(user, "codex", "openai/gpt-6-astra")

    stub(Inference, :usable?, fn _, _, _ -> {:ok, true} end)

    stub(Ravix.Fountain, :client, fn -> FakeTransport.client([], verify: false) end)

    stub(Ravix.MachineCache, :catalog, fn _ -> {:ok, @catalog} end)

    assert {:ok, %{preferred_runtime: :codex, preferred_model: "openai/gpt-6-astra"}} =
             ThreadPreference.save(user, "codex", "openai/gpt-6-astra")
  end
end
