defmodule Ravix.RoutinesRaceTest do
  @moduledoc "Committed PostgreSQL claims on independent connections, as concurrent app instances see them."
  use ExUnit.Case, async: false
  import Ravix.Factory
  alias Ecto.Adapters.SQL.Sandbox
  alias Ravix.{Crypto, Repo, Routines}
  alias Ravix.Routines.Store

  setup do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      project = insert_project(user: user)
      {:ok, row, token} = Routines.create(user, project.id, %{name: "Race", prompt: "Inspect"})

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete!(project)
          Repo.delete!(user)
        end)
      end)

      %{row: row, token: token}
    end)
  end

  test "a concurrent duplicate waits for the first claim and returns its durable identity", ctx do
    parent = self()

    first =
      spawn_link(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, result} =
            Repo.transaction(fn ->
              result = Store.claim(ctx.row.id, ctx.token, "same-event", Crypto.sha256("{}"))
              send(parent, {:claimed, self(), result})

              receive do
                :commit -> result
              end
            end)

          send(parent, {:committed, result})
        end)
      end)

    assert_receive {:claimed, ^first, {:ok, {:new, _, _, dispatch}}}, 5_000

    second =
      spawn_link(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, {:second_started, self()})

          send(
            parent,
            {:duplicate, Store.claim(ctx.row.id, ctx.token, "same-event", Crypto.sha256("{}"))}
          )
        end)
      end)

    monitor = Process.monitor(second)
    assert_receive {:second_started, ^second}
    refute_receive {:duplicate, _}, 100
    send(first, :commit)
    assert_receive {:committed, {:ok, {:new, _, _, _}}}, 5_000
    assert_receive {:duplicate, {:ok, {:duplicate, persisted}}}, 5_000
    assert persisted.id == dispatch.id
    assert_receive {:DOWN, ^monitor, :process, ^second, :normal}

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, [row]} = Routines.history(inserted_user(ctx.row.user_id), ctx.row.id)
      assert row.id == dispatch.id
    end)
  end

  defp inserted_user(id), do: Repo.get!(Ravix.Accounts.User, id)
end
