defmodule Ravix.PromptQueue.Recovery do
  @moduledoc """
  Context replay on the next queued prompt after a session reset.

  Scans one page at a time, forward from the last sent receipt's cursor. Both
  the cursor and any preamble remain tentative through ambiguous delivery;
  confirmation by any worker commits them with the queue row's sent status.

  Sent history without a cursor identifies an upgrade: the first successful
  delivery baselines at the current tail, without replaying historical resets.
  A new thread with no sent history starts at zero so an opening-turn reset
  still restores context on its first queued prompt.
  """

  alias Ravix.Fountain
  alias Ravix.Plans.Status
  alias Ravix.Projects.Project
  alias Ravix.PromptQueue.Item
  alias Ravix.PromptQueue.Store
  alias Ravix.Spec
  alias Ravix.Tracks.CredentialRecovery
  alias Ravix.Tracks.Track

  @doc "Remove a complete leading recovery block and report whether context was restored."
  @spec visible_prompt(String.t()) :: {String.t(), boolean()}
  def visible_prompt(prompt) do
    case Regex.run(
           ~r/\A\[ravix: session context restored\]\n.*?\n\[\/ravix: session context restored\]\n\n(.*)\z/s,
           prompt
         ) do
      [_, body] -> {body, true}
      nil -> {prompt, false}
    end
  end

  @doc "Scan new events and persist the context attached to this claimed delivery."
  @spec prepare(Fountain.Client.t(), Item.t(), Track.t(), Project.t()) ::
          {:ok, String.t()} | :lost_claim | {:error, :context_unavailable}
  def prepare(client, row, track, project) do
    {cursor, baseline?} = Store.recovery_scan(row.thread_id)
    last = Store.delivered_reset(row.thread_id)
    state = %{scan: cursor, reset: last, baseline?: baseline?}

    with {:ok, scanned} <- scan(client, track.conversation_id, cursor, state) do
      # ownership: Server.access admitted this queued sender through Access.thread_access.
      thread =
        if CredentialRecovery.enabled?(track, project),
          do: Ravix.Tracks.Store.thread(track.id, row.thread_id)

      restore? = thread && thread.recovery_context_pending
      preamble = if scanned.reset > last or restore?, do: preamble(track, project), else: ""
      reset = if preamble == "", do: nil, else: scanned.reset

      if Store.prepare_recovery(row.id, row.claim_token, reset, scanned.scan),
        do: {:ok, preamble},
        else: :lost_claim
    end
  end

  defp scan(client, conversation, cursor, state) do
    case Fountain.events_page(client, conversation, after: cursor) do
      {:ok, page} ->
        state = Enum.reduce(page.events, state, &advance(&1, &2, cursor))
        next = page.next_cursor
        state = if is_integer(next), do: %{state | scan: max(state.scan, next)}, else: state

        cond do
          not page.has_more -> {:ok, state}
          is_integer(next) and next > cursor -> scan(client, conversation, next, state)
          true -> {:error, :context_unavailable}
        end

      {:error, _reason} ->
        {:error, :context_unavailable}
    end
  end

  defp advance(%{"id" => id} = event, state, cursor) when is_integer(id) and id > cursor do
    reset =
      if not state.baseline? and reset?(event), do: max(state.reset, id), else: state.reset

    %{state | scan: max(state.scan, id), reset: reset}
  end

  defp advance(_event, state, _cursor), do: state

  defp preamble(track, project) do
    # ownership: Server.access/1 established Access.thread_access for the
    # queued sender; only that track's assigned material and derived statuses
    # belong in replay, not its siblings or the rest of the project plan.
    items = Ravix.Plans.Store.for_track(track.id)
    Spec.session_recovery_prompt(track, Status.items(project, items))
  end

  defp reset?(%{"kind" => "stage", "data" => data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"reason" => "session_gone"}} -> true
      _ -> false
    end
  end

  defp reset?(_event), do: false
end
