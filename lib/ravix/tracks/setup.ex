defmodule Ravix.Tracks.Setup do
  @moduledoc """
  Durable opening-turn reconciliation, driven by the queue's periodic sweep even
  without a queued prompt. PostgreSQL leases serialize instances; request ids
  survive a crash between POST and response. No browser or follower owns setup.
  """
  alias Ravix.{Fountain, Hub, Spec}
  alias Ravix.Tracks.{Origin, Store, Transcript}
  alias Ravix.Tracks.Transcript.Event

  @max_attempts 3
  @settle_seconds 600
  @failure "setup_failed: Track setup failed after automatic retries. Retry track setup, then retry this saved prompt."

  def failure_message, do: @failure

  # ownership: the queue worker reconciles only open tracks returned by
  # Tracks.Store.pending_setups/0. Scoped Tracks.open/retry also enter here
  # after Access has admitted the caller. The lease is the write authority.
  def advance(client, id) do
    case Store.claim_setup(id) do
      nil ->
        :ok

      track ->
        try do
          # ownership: no door — this durable setup lease belongs to the track
          # whose project is needed to reconstruct its opening instructions.
          project = Ravix.Projects.Store.live_project(track.project_id)
          if project, do: step(client, track, project)
        after
          Store.update_setup(track, setup_lease: nil, setup_lease_until: nil)
        end
    end
  end

  defp step(client, %{setup_state: "pending", opened_at: nil} = track, project),
    do: send_opening(client, track, project)

  # Before this gate existed, opened_at meant accepted, not completed. Check
  # those tracks' actual first opening turn too, instead of grandfathering them.
  defp step(client, %{setup_state: "pending"} = track, project) do
    attrs = [setup_state: "running", setup_attempts: 1, setup_started_at: track.created_at]
    if Store.update_setup(track, attrs), do: reconcile(client, struct(track, attrs), project)
  end

  defp step(client, %{setup_state: "retry"} = track, project) do
    if due?(track.setup_retry_at), do: send_opening(client, track, project)
  end

  defp step(client, track, project), do: reconcile(client, track, project)

  defp send_opening(client, track, project) do
    attrs = [
      setup_state: "running",
      setup_attempts: track.setup_attempts + 1,
      setup_request_id: Ecto.UUID.generate(),
      setup_started_at: DateTime.utc_now(),
      setup_retry_at: nil,
      setup_error: nil
    ]

    if Store.update_setup(track, attrs) do
      track = struct(track, attrs)
      prompt = Spec.open_track_prompt(project, Origin.from_row(track), track.slug, track.branch)

      post_opening(client, track, project, prompt)
    end
  end

  defp post_opening(client, track, project, prompt) do
    case Ravix.Projects.prepare_machine(project, client) do
      :ok ->
        client
        |> Fountain.prompt(track.conversation_id, prompt, [],
          client_request_id: track.setup_request_id
        )
        |> sent(track)

      {:error, _} ->
        failed(track, "The machine could not be prepared for setup.")
    end
  end

  defp sent({:error, %Fountain.Error{} = error}, track) do
    cond do
      Fountain.Error.busy?(error) ->
        Store.update_setup(track,
          setup_state: "retry",
          setup_attempts: track.setup_attempts - 1,
          setup_retry_at: DateTime.add(DateTime.utc_now(), 30, :second)
        )

        publish(track)

      Fountain.Error.rejected?(error) ->
        failed(track, "Opening prompt was refused: #{error.code}")

      true ->
        publish(track)
    end
  end

  defp sent(_outcome, track), do: publish(track)

  defp reconcile(client, track, project) do
    with {:ok, conversation} <- Fountain.get_conversation(client, track.conversation_id),
         {:ok, turns} <- Fountain.turns(client, track.conversation_id) do
      turn = opening_turn(turns, track)
      outcome(client, track, project, conversation, turn)
    end
  end

  defp opening_turn(turns, %{setup_request_id: nil}) do
    turns
    |> Enum.filter(
      &(is_binary(&1.prompt) and String.starts_with?(&1.prompt, "[ravix] Open this track"))
    )
    |> Enum.max_by(&(&1.inserted_at || ""), fn -> nil end)
  end

  defp opening_turn(turns, track),
    do: Enum.find(turns, &(&1.client_request_id == track.setup_request_id))

  defp outcome(client, track, project, conversation, %{status: "completed"}) do
    case worktree(client, track, project, conversation.sandbox_id) do
      :ok ->
        if Store.update_setup(track,
             setup_state: "ready",
             opened_at: DateTime.utc_now(),
             setup_error: nil
           ),
           do: publish(track)

      :missing ->
        failed(track, "The opening turn finished without creating its worktree.")

      :unavailable ->
        :ok
    end
  end

  defp outcome(client, track, _project, _conversation, %{status: status})
       when status in ["failed", "cancelled", "canceled", "interrupted"] do
    failed(track, failure_reason(client, track))
  end

  defp outcome(client, track, _project, conversation, _turn) do
    cond do
      Fountain.Shapes.ended?(conversation) -> failed(track, failure_reason(client, track))
      Fountain.Shapes.busy?(conversation) -> :ok
      expired?(track) -> failed(track, "The opening turn's outcome could not be confirmed.")
      true -> :ok
    end
  end

  defp worktree(_client, _track, _project, nil), do: :unavailable

  defp worktree(client, track, project, sandbox_id) do
    case Fountain.listing(client, sandbox_id, track.workdir) do
      {:ok, %{"path" => path, "entries" => entries}}
      when path == track.workdir and is_list(entries) ->
        if is_nil(project.repo_full_name) or Enum.any?(entries, &(&1["name"] == ".git")),
          do: :ok,
          else: :missing

      {:ok, _} ->
        :missing

      {:error, %Fountain.Error{status: 404}} ->
        :missing

      {:error, _} ->
        :unavailable
    end
  end

  defp failed(track, reason) do
    exhausted? = track.setup_attempts >= @max_attempts

    attrs = [
      setup_state: if(exhausted?, do: "failed", else: "retry"),
      setup_error: reason,
      setup_retry_at: DateTime.add(DateTime.utc_now(), backoff(track.setup_attempts), :second)
    ]

    if Store.update_setup(track, attrs) do
      # ownership: no door — this setup lease belongs to this track; only queued rows
      # are failed, preserving bodies and leaving already-delivered turns alone.
      if exhausted?, do: Ravix.PromptQueue.Store.fail_setup(track.id, @failure <> " " <> reason)
      publish(track)
    end
  end

  defp failure_reason(client, track) do
    with {:ok, events} <- Fountain.events(client, track.conversation_id),
         %Event{} = event <-
           events
           |> Enum.reverse()
           |> Enum.map(&Event.from/1)
           |> Enum.find(&Event.failed_stage?/1),
         reason when reason != "" <- Transcript.failure_reason(event) do
      reason
    else
      _ -> "The opening turn failed."
    end
  end

  defp backoff(1), do: 5
  defp backoff(_), do: 30
  defp due?(nil), do: true
  defp due?(at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp expired?(track),
    do:
      DateTime.diff(DateTime.utc_now(), track.setup_started_at || track.created_at) >=
        @settle_seconds

  defp publish(track), do: Hub.publish(track.project_id, :turn, track_id: track.id)
end
