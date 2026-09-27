defmodule Ravix.DedicatedOpenFlagTest do
  use ExUnit.Case, async: false

  test "dedicated opens default off and opt in only explicit user IDs" do
    previous = Application.fetch_env(:ravix, :dedicated_open_user_ids)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ravix, :dedicated_open_user_ids, value)
        :error -> Application.delete_env(:ravix, :dedicated_open_user_ids)
      end
    end)

    user = %Ravix.Accounts.User{id: "allowed"}
    Application.delete_env(:ravix, :dedicated_open_user_ids)
    refute Ravix.Config.dedicated_opens_enabled?(user)
    Application.put_env(:ravix, :dedicated_open_user_ids, ["allowed"])
    assert Ravix.Config.dedicated_opens_enabled?(user)
    refute Ravix.Config.dedicated_opens_enabled?(%{user | id: "other"})
    Application.put_env(:ravix, :dedicated_open_user_ids, [])
    refute Ravix.Config.dedicated_opens_enabled?(user)
  end
end
