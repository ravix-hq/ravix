defmodule Ravix.Previews.ServerFailureTest do
  use Ravix.DataCase, async: true, group: :preview_ports
  use Mimic
  import Ravix.PreviewsFixture
  alias Ravix.{Previews, Tracks}
  alias Ravix.Previews.Server

  setup do
    provider = start_provider()
    stub_provider(provider)
    user = insert_user()
    project = insert_project(user: user)
    track = insert_track(project: project, conversation_id: "conversation")
    %{user: user, project: project, track: track}
  end

  test "a missing configuration fails visibly and remains retryable", ctx do
    assert :ok = Previews.start_service(ctx.track.id)
    assert %{state: :failed, error: message} = Previews.info(ctx.track.id)
    assert message =~ "Save a preview startup command"
  end

  test "a missing machine explains how to recover", ctx do
    configure(ctx)
    stub(Tracks, :machine_of, fn _, _ -> {:ok, nil} end)
    assert :ok = Previews.start_service(ctx.track.id)
    assert %{state: :failed, error: message} = Previews.info(ctx.track.id)
    assert message =~ "Open a track first"
  end

  test "provider errors settle startup instead of leaving the preview starting", ctx do
    configure(ctx)
    stub(Tracks, :machine_of, fn _, _ -> {:error, {:unavailable, "Fountain is offline"}} end)
    assert :ok = Previews.start_service(ctx.track.id)
    assert %{state: :failed, error: "Fountain is offline"} = Previews.info(ctx.track.id)
    refute Server.busy?(ctx.track.id)
  end

  test "idle preview processes stop and can be recreated", ctx do
    pid = Server.ensure(ctx.track.id)
    send(pid, :unrelated)
    assert Process.alive?(pid)
    monitor = Process.monitor(pid)
    send(pid, :timeout)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    replacement = Server.ensure(ctx.track.id)
    assert replacement != pid
    assert :ok = Server.stop(ctx.track.id)
    refute Process.alive?(replacement)
    assert :ok = Server.stop(ctx.track.id)
  end

  @tag capture_log: true
  test "an unexpected provider exception clears the busy marker", ctx do
    configure(ctx)
    stub(Tracks, :machine_of, fn _, _ -> raise "unexpected failure" end)

    assert {:error, %RuntimeError{message: "unexpected failure"}} =
             Previews.start_service(ctx.track.id)

    refute Server.busy?(ctx.track.id)
  end

  defp configure(ctx) do
    {:ok, _} =
      Previews.set_defaults(ctx.user, ctx.project.id, %{
        directory: ".",
        command: "npm start",
        readiness_path: "/"
      })
  end
end
