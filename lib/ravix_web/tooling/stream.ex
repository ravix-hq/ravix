defmodule RavixWeb.Tooling.Stream do
  @moduledoc "Request-owned A2A streams. Every poll revalidates credentials and membership."
  import Plug.Conn
  alias Ravix.Tooling.Tasks
  alias RavixWeb.Tooling.{A2A, RPC}

  @duration_ms 55_000

  def start(conn, id, principal, task) do
    case Tasks.get(principal, task.id) do
      {:ok, task} ->
        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-store")
          |> send_chunked(200)

        case emit(conn, id, %{task: Tasks.present(task)}) do
          {:ok, conn} -> stream(conn, id, principal, task, deadline())
          {:error, _} -> conn
        end

      error ->
        failure(conn, id, error)
    end
  end

  def wait(conn, id, principal, task), do: wait_until(conn, id, principal, task, deadline())

  defp wait_until(conn, id, principal, task, deadline) do
    cond do
      Tasks.terminal?(task) ->
        Phoenix.Controller.json(conn, RPC.result(id, %{task: Tasks.present(task)}))

      expired?(deadline) ->
        Phoenix.Controller.json(
          conn,
          RPC.error(id, -32_000, "Wait timed out; work continues. GetTask #{task.id}")
        )

      true ->
        tick()

        case Tasks.get(principal, task.id) do
          {:ok, next} -> wait_until(conn, id, principal, next, deadline)
          error -> failure(conn, id, error)
        end
    end
  end

  defp stream(conn, id, principal, task, deadline) do
    if Tasks.terminal?(task) or expired?(deadline) do
      conn
    else
      tick()

      case Tasks.get(principal, task.id) do
        {:ok, next} ->
          emit_updates(conn, id, principal, task, next, deadline)

        error ->
          stream_error(conn, id, error)
      end
    end
  end

  defp stream_error(conn, id, error) do
    {:error, code, message} = A2A.error_result(error)

    case chunk(conn, "data: " <> Jason.encode!(RPC.error(id, code, message)) <> "\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp emit_updates(conn, id, principal, previous, task, deadline) do
    view = Tasks.present(task)

    artifact = %{
      artifactUpdate: %{
        taskId: task.id,
        contextId: task.track_id,
        artifact: hd(view.artifacts),
        append: false,
        lastChunk: Tasks.terminal?(task)
      }
    }

    status = %{statusUpdate: %{taskId: task.id, contextId: task.track_id, status: view.status}}
    messages = if previous.result != task.result, do: [artifact, status], else: [status]

    outcome =
      Enum.reduce_while(messages, {:ok, conn}, fn msg, {:ok, acc} ->
        case emit(acc, id, msg) do
          {:ok, _} = ok -> {:cont, ok}
          error -> {:halt, error}
        end
      end)

    case outcome do
      {:ok, conn} -> stream(conn, id, principal, task, deadline)
      {:error, _} -> conn
    end
  end

  defp emit(conn, id, value),
    do: chunk(conn, "data: " <> Jason.encode!(RPC.result(id, value)) <> "\n\n")

  defp failure(conn, id, error) do
    {:error, code, message} = A2A.error_result(error)
    Phoenix.Controller.json(conn, RPC.error(id, code, message))
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @duration_ms
  defp expired?(at), do: System.monotonic_time(:millisecond) >= at

  defp tick do
    ref = make_ref()
    Process.send_after(self(), {:tooling_poll, ref}, 1000)

    receive do
      {:tooling_poll, ^ref} -> :ok
    end
  end
end
