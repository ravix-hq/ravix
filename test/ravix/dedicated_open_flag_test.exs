defmodule Ravix.DedicatedOpenFlagTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.fetch_env(:ravix, :dedicated_open_user_ids)
    env = System.get_env("RAVIX_DEDICATED_OPEN_USER_IDS")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :dedicated_open_user_ids, value)
        :error -> Application.delete_env(:ravix, :dedicated_open_user_ids)
      end

      if env,
        do: System.put_env("RAVIX_DEDICATED_OPEN_USER_IDS", env),
        else: System.delete_env("RAVIX_DEDICATED_OPEN_USER_IDS")
    end)
  end

  test "wildcard enables dedicated opens for everyone and keeps rollout active" do
    configure(" * ")
    assert Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: "one"})
    assert Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: "another"})
    assert Ravix.Config.dedicated_rollout?()
  end

  test "explicit IDs enable only the listed users and keep rollout active" do
    configure(" allowed, second, , ")
    assert Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: "allowed"})
    assert Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: "second"})
    refute Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: "other"})
    assert Ravix.Config.dedicated_rollout?()
  end

  test "empty and unset values disable dedicated opens and rollout" do
    for value <- [nil, "", " , "] do
      configure(value)
      refute Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: "any"})
      refute Ravix.Config.dedicated_rollout?()
    end

    Application.delete_env(:ravix, :dedicated_open_user_ids)
    refute Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: "any"})
    refute Ravix.Config.dedicated_rollout?()
  end

  defp configure(value) do
    if value,
      do: System.put_env("RAVIX_DEDICATED_OPEN_USER_IDS", value),
      else: System.delete_env("RAVIX_DEDICATED_OPEN_USER_IDS")

    config = Config.Reader.read!("config/runtime.exs", env: :test)

    Application.put_env(
      :ravix,
      :dedicated_open_user_ids,
      config[:ravix][:dedicated_open_user_ids]
    )
  end
end
