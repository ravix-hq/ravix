defmodule Ravix.Tracks.Billing do
  @moduledoc """
  Who pays for a track's inference, and what happens when they cannot
  (ADR 0009 phase 6; `docs/creator-billing.md` is the contract).

  A dedicated track opened while `RAVIX_CREATOR_BILLING` is on is paid for by
  its creator, for every thread and harness on it, whoever prompts. Every
  other track is its project owner's (ADR 0005), including every track that
  was open before the switch was flipped: nothing here converts one.
  `Ravix.Tracks.Track.payer/2` is the only reader of the recorded policy and
  `payer/2` below the only place it becomes a person.

  ## Binding

  A creator-billed conversation names its payer's set in
  `inference_credential_id` on every create --- the first thread, every later
  thread, the machine's opening conversation, and a credential-recovery
  successor --- because Fountain pins a conversation to the source it was
  admitted with and a create that names nothing runs on the agent's default,
  which is the project owner's (`docs/creator-billing.md` §1). `bind/3` puts
  the set there and `verify/3` refuses a launch that names nothing or
  something else. The set comes from the track's recorded payer, never from a
  request.

  ## Pauses

  When the payer's credential stops serving, new turns on that harness on
  that track wait, with a reason everybody on the track is shown. A pause is
  lifted when the payer reconnects that agent (a newer connection than the
  pause, read off the payer's row), when the time Fountain said the
  subscription resets has passed, or when the payer asks to try again. Nobody
  else's credential is ever used instead.

  Fountain says why only for Codex on a ChatGPT subscription
  (`chatgpt_grant_unusable` with a `reason` and, for exhaustion, an `until`).
  A Claude subscription or an API key fails the turn with the runtime's own
  text, so `from_failure/3` recognises only auth- and quota-shaped failures,
  and says "until" only when the text carries a time. It never invents one.
  """

  require Logger

  alias Ravix.Accounts.User
  alias Ravix.AgentName
  alias Ravix.Fountain
  alias Ravix.Fountain.{Error, Launch}
  alias Ravix.Hub
  alias Ravix.Projects.{EnvironmentVariables, Project, RuntimeAgents}
  alias Ravix.PromptQueue.Server, as: QueueServer
  alias Ravix.Trace
  alias Ravix.Tracks.{Store, Track}
  alias Ravix.Tracks.Transcript.Event

  @type reason :: {:conflict, String.t(), String.t()}
  @type pause :: %{optional(String.t()) => String.t() | nil}

  # A failed turn older than this is history being classified, not a
  # credential failing now, and pauses nothing.
  @recent_failure_seconds 30 * 60
  # The furthest reset time read out of a runtime's text that is believed:
  # a week and a day, Fountain's own ceiling for a subscription's window.
  @max_until_seconds 8 * 86_400

  # ── who pays ─────────────────────────────────────────────────────────

  @doc """
  The person who pays for `track`'s inference, as a fresh row.

  A creator-billed track whose payer's account is gone is refused, never
  moved onto the project's owner.
  """
  @spec payer(Track.t(), Project.t()) :: {:ok, User.t()} | {:error, reason()}
  def payer(%Track{} = track, %Project{} = project) do
    case Track.payer(track, project) do
      {:creator, id} when is_binary(id) ->
        # ownership: callers hold the track through Access.track_access/2 or a queue
        # row re-admitted by Access.thread_access/3; the payer is the row it recorded.
        case Ravix.Accounts.Store.get_user(id) do
          %User{} = user -> {:ok, user}
          nil -> payer_gone()
        end

      {:creator, nil} ->
        payer_gone()

      {:legacy_owner, _owner_id} ->
        case RuntimeAgents.owner(project) do
          %User{} = owner -> {:ok, owner}
          nil -> payer_gone()
        end
    end
  end

  @doc "Whether a track opened by `user` now is paid for by them."
  @spec creator_opening?() :: boolean()
  def creator_opening?, do: Ravix.Config.creator_billing?()

  @doc """
  Whether this dedicated track's conversations name their payer's set and
  its agents admit it, rather than following the project agent's default.
  A creator-billed track always does; an owner-billed one does while its
  owner is in the dedicated maintenance cohort, as before.
  """
  @spec maintained?(Track.t(), Project.t()) :: boolean()
  def maintained?(%Track{} = track, %Project{} = project),
    do:
      track.sandbox_layout == :dedicated and
        (Track.creator_billed?(track) or Project.maintenance?(project))

  @doc "The payer's credential set, or a refusal saying they have connected nothing."
  @spec payer_set(User.t()) :: {:ok, String.t()} | {:error, reason()}
  def payer_set(%User{credential_set_id: id}) when is_binary(id) and id != "", do: {:ok, id}

  def payer_set(%User{login: login}),
    do:
      {:error,
       {:conflict, "payer_not_connected",
        "@#{login} hasn't connected an agent, so this track cannot run."}}

  @doc """
  What `Ravix.Tracks.Runtime.select/7` needs to choose a harness on this
  track: whose credentials decide which harnesses are usable, and, on a
  creator-billed track, the set every agent must admit.
  """
  @spec select_opts(Track.t(), Project.t()) :: {:ok, keyword()} | {:error, reason()}
  def select_opts(%Track{} = track, %Project{} = project) do
    with {:ok, payer} <- payer(track, project), do: payer_opts(track, payer)
  end

  defp payer_opts(track, payer) do
    if Track.creator_billed?(track),
      do: with({:ok, set} <- payer_set(payer), do: {:ok, [payer: payer, payer_set: set]}),
      else: {:ok, [payer: payer]}
  end

  # ── launches ─────────────────────────────────────────────────────────

  @doc """
  Put the payer's set on a conversation this track is about to create.

  Creator-billed: the creator's set, verified. Owner-billed and maintained:
  the owner's set, which is what `Maintenance.adopt/2` did before creator
  billing. Otherwise the launch is left to its agent's default, exactly as
  before.
  """
  @spec bind(Launch.t(), Track.t(), Project.t()) :: {:ok, Launch.t()} | {:error, reason()}
  def bind(%Launch{} = launch, %Track{} = track, %Project{} = project) do
    cond do
      Track.creator_billed?(track) ->
        with {:ok, payer} <- payer(track, project),
             {:ok, set} <- payer_set(payer),
             do: verify(%{launch | inference_credential_id: set}, track, project)

      Project.maintenance?(project) ->
        {:ok, %{launch | inference_credential_id: RuntimeAgents.owner(project).credential_set_id}}

      true ->
        {:ok, launch}
    end
  end

  @doc """
  Refuse a creator-billed launch that does not name its payer's set.

  A create with no `inference_credential_id` runs on the agent's default,
  which is the project owner's set, so a nil here is exactly the silent
  fallback creator billing forbids; a different id is somebody else paying.
  """
  @spec verify(Launch.t(), Track.t(), Project.t()) :: {:ok, Launch.t()} | {:error, reason()}
  def verify(%Launch{} = launch, %Track{} = track, %Project{} = project) do
    if Track.creator_billed?(track) do
      with {:ok, payer} <- payer(track, project),
           {:ok, set} <- payer_set(payer),
           do: named(launch, set, payer)
    else
      {:ok, launch}
    end
  end

  defp named(%Launch{inference_credential_id: set} = launch, set, _payer), do: {:ok, launch}

  defp named(_launch, _set, payer),
    do:
      {:error,
       {:conflict, "payer_mismatch",
        "This track's agent must run on @#{payer.login}'s account, and this launch did not."}}

  @doc """
  The one door a dedicated track's conversation is created through: the
  launch is verified against the track's payer immediately before the POST,
  whatever built it, and a creator-billed create is logged by track, payer
  and set id (never a credential). A refused launch reaches no provider.
  """
  @spec create_conversation(Fountain.Client.t(), Launch.t(), Track.t(), Project.t()) ::
          {:ok, term()} | {:error, term()}
  def create_conversation(client, %Launch{} = launch, %Track{} = track, %Project{} = project) do
    with {:ok, launch} <- verify(launch, track, project) do
      if Track.creator_billed?(track) do
        Logger.info(
          "ravix: creator billing launch track=#{track.id} payer=#{track.payer_user_id} set=#{launch.inference_credential_id}"
        )

        Trace.annotate(%{
          "ravix.billing_policy" => "creator",
          "ravix.payer_user_id" => track.payer_user_id,
          "ravix.credential_set_id" => launch.inference_credential_id
        })
      end

      Fountain.create_conversation(client, launch)
    end
  end

  @doc "Admit the payer's set on `agent_id` before a creator-billed create; nothing otherwise."
  @spec admit(Fountain.Client.t(), Track.t(), Project.t(), String.t()) :: :ok | {:error, term()}
  def admit(client, %Track{} = track, %Project{} = project, agent_id) do
    if Track.creator_billed?(track) do
      with {:ok, payer} <- payer(track, project),
           {:ok, set} <- payer_set(payer),
           {:ok, _agent_id} <- RuntimeAgents.admit_payer(client, agent_id, set),
           do: :ok
    else
      :ok
    end
  end

  # ── provider-named overrides ────────────────────────────────────────

  @doc """
  Refuse a creator-billed open or launch while the project environment or
  the vault it runs with holds a provider-named variable or secret.

  Fountain lets such a value outrank the conversation's set
  (`docs/creator-billing.md` §2), so it would bill whoever saved it rather
  than the creator. Names only: the environment's readable values are
  dropped unread past their keys, and secrets come back as keys.
  """
  @spec refuse_overrides(Fountain.Client.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, reason() | term()}
  def refuse_overrides(client, environment_id, vault_id) do
    with {:ok, names} <- provider_names(client, environment_id, vault_id) do
      case names do
        [] ->
          :ok

        names ->
          {:error,
           {:conflict, "provider_secret",
            "This track is paid for by its creator, but the project holds #{Enum.join(names, ", ")}, which would bill whoever saved it instead. Remove it from Project settings › Secrets, then try again."}}
      end
    end
  end

  @doc "Provider-named variable and secret names in an environment and a vault, sorted."
  @spec provider_names(Fountain.Client.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  def provider_names(client, environment_id, vault_id) do
    with {:ok, env} <- environment_names(client, environment_id),
         {:ok, vault} <- secret_names(client, :vaults, vault_id) do
      auth = EnvironmentVariables.auth_names()
      {:ok, (env ++ vault) |> Enum.filter(&(&1 in auth)) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @typedoc "One project's provider-named values, by name only, as `inventory/1` finds them."
  @type finding :: %{
          project_id: String.t(),
          name: String.t(),
          environment: [String.t()] | {:error, term()},
          vault: [String.t()] | {:error, term()}
        }

  @doc """
  The activation runbook's check: every live project whose environment or
  vault holds a provider-named variable or secret, which would refuse its
  creator-billed opens and launches once `RAVIX_CREATOR_BILLING` is on.

  Names only. No value is read past its key, and nothing is written. A
  project Fountain could not be asked about is listed with the error rather
  than dropped, so an unreadable project is not mistaken for a clean one.
  """
  @spec inventory(Fountain.Client.t()) :: [finding()]
  def inventory(client) do
    # ownership: no door; an operator task with no user in hand, reading names only.
    Ravix.Projects.Store.live_projects()
    |> Enum.map(fn project ->
      %{
        project_id: project.id,
        name: project.name,
        environment: names_or_error(environment_names(client, project.environment_id)),
        vault: names_or_error(secret_names(client, :vaults, project.vault_id))
      }
    end)
    |> Enum.filter(fn finding ->
      finding.environment != [] or finding.vault != []
    end)
  end

  defp names_or_error({:ok, names}) do
    auth = EnvironmentVariables.auth_names()
    names |> Enum.filter(&(&1 in auth)) |> Enum.uniq() |> Enum.sort()
  end

  defp names_or_error({:error, reason}), do: {:error, Ravix.Redact.reason(reason)}

  defp environment_names(_client, nil), do: {:ok, []}

  defp environment_names(client, id) do
    with {:ok, environment} <- Fountain.get_environment(client, id),
         {:ok, secrets} <- secret_names(client, :environments, id) do
      variables =
        case environment do
          %{"env_vars" => vars} when is_map(vars) -> Map.keys(vars)
          _ -> []
        end

      {:ok, variables ++ secrets}
    end
  end

  defp secret_names(_client, _store, nil), do: {:ok, []}

  defp secret_names(client, store, id) do
    with {:ok, rows} <- Fountain.secret_keys(client, store, id),
         do: {:ok, for(%{"key" => key} when is_binary(key) <- rows, do: key)}
  end

  # ── pauses ───────────────────────────────────────────────────────────

  @doc """
  The pause standing on this harness of this track, or nil.

  `payer` is the payer's current row: a connection of the harness's agent
  newer than the pause lifts it, as does a reset time that has passed.
  """
  @spec paused(Track.t(), String.t() | nil, User.t() | nil, DateTime.t()) :: pause() | nil
  def paused(track, runtime, payer, now \\ DateTime.utc_now())

  def paused(%Track{billing_pauses: pauses}, runtime, payer, now)
      when is_map(pauses) and is_binary(runtime) do
    case pauses[runtime] do
      %{"at" => at} = pause when is_binary(at) ->
        if waiting?(pause, now) and not reconnected?(payer, runtime, at), do: pause

      _ ->
        nil
    end
  end

  def paused(_track, _runtime, _payer, _now), do: nil

  @doc "Every standing pause on the track, by runtime."
  @spec pauses(Track.t(), User.t() | nil) :: %{String.t() => pause()}
  def pauses(%Track{billing_pauses: pauses} = track, payer) when is_map(pauses) do
    for {runtime, _} <- pauses,
        pause = paused(track, runtime, payer),
        into: %{},
        do: {runtime, pause}
  end

  def pauses(_track, _payer), do: %{}

  defp waiting?(%{"until" => until}, now) when is_binary(until) do
    case DateTime.from_iso8601(until) do
      {:ok, at, _} -> DateTime.compare(at, now) == :gt
      _ -> true
    end
  end

  defp waiting?(_pause, _now), do: true

  defp reconnected?(%User{credential_connected_at: stamps}, runtime, at) when is_map(stamps) do
    prefix = agent_of(runtime) <> ":"

    Enum.any?(stamps, fn {connection, stamp} ->
      String.starts_with?(connection, prefix) and is_binary(stamp) and stamp > at
    end)
  end

  defp reconnected?(_payer, _runtime, _at), do: false

  @doc """
  Pause `runtime` on `track`, and tell the track's pages. Only a
  creator-billed track is ever paused: an owner-billed one keeps the owner's
  own handling, unchanged.
  """
  @spec pause(Track.t(), String.t(), pause()) :: :ok
  def pause(%Track{} = track, runtime, %{} = pause) when is_binary(runtime) do
    if Track.creator_billed?(track) do
      # ownership: callers hold the track through Access or a queue row's
      # re-admitted sender; the pause names only the recorded payer.
      :ok = Store.pause_billing(track.id, runtime, pause)

      Logger.info(
        "ravix: creator billing paused #{runtime} on track #{track.id} (#{pause["code"]})"
      )

      Trace.annotate(%{
        "ravix.billing_pause" => pause["code"],
        "ravix.billing_runtime" => runtime
      })

      Hub.publish(track.project_id, :tracks, track_id: track.id)
    end

    :ok
  end

  @doc "Lift the pause that was read, leaving any newer one."
  @spec resume(Track.t(), String.t(), pause()) :: :ok | {:error, :stale_pause}
  def resume(%Track{} = track, runtime, %{} = pause) do
    # ownership: `Tracks.resume_billing/3` admitted the payer through Access.
    with :ok <- Store.resume_billing(track.id, runtime, pause) do
      Hub.publish(track.project_id, :tracks, track_id: track.id)
      QueueServer.wake()
    end
  end

  @doc """
  The pause a Fountain refusal means for a creator-billed track, or nil when
  it is not about the payer's credential.
  """
  @spec from_error(Error.t(), User.t(), String.t()) :: pause() | nil
  def from_error(%Error{code: "chatgpt_grant_unusable"} = error, %User{} = payer, _runtime) do
    reason =
      case error.grant_reason do
        "exhausted" -> "@#{payer.login}'s ChatGPT subscription is out of quota"
        "revoked" -> "@#{payer.login}'s ChatGPT subscription was revoked"
        "expired" -> "@#{payer.login}'s ChatGPT subscription expired"
        "disconnected" -> "@#{payer.login}'s ChatGPT subscription was disconnected"
        _ -> "@#{payer.login}'s ChatGPT subscription needs reconnecting"
      end

    build("chatgpt_grant_unusable", reason, payer, error.until, error.grant_reason)
  end

  def from_error(%Error{code: "inference_credential_unusable"}, %User{} = payer, runtime),
    do:
      build(
        "inference_credential_unusable",
        "@#{payer.login} hasn't connected #{AgentName.label(runtime)}",
        payer,
        nil,
        nil
      )

  def from_error(_error, _payer, _runtime), do: nil

  @auth ~r/\b401\b|unauthori[sz]ed|authentication[_ ]error|invalid[ _-]?(x-)?api[ _-]?key|invalid bearer|(oauth )?token (has )?(expired|been revoked|was revoked)|invalid_grant|please run \/login|credentials? (are |were )?(invalid|expired|revoked)/i
  @quota ~r/usage limit|out of quota|insufficient_quota|quota exceeded|credit balance is too low|limit reached|hit your limit|out of (credits|usage)/i

  @doc """
  The pause a failed turn's own words mean, or nil.

  `data` is the failed stage's metadata as Fountain sent it. A structured
  `chatgpt_grant_unusable` there is read like the HTTP refusal; otherwise
  only auth- and quota-shaped text pauses anything, and a transient rate
  limit, an outage or a crash does not.
  """
  @spec from_failure(String.t() | nil, User.t(), String.t()) :: pause() | nil
  def from_failure(data, %User{} = payer, runtime) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"reason" => "chatgpt_grant_unusable"} = meta} ->
        error = %Error{
          code: "chatgpt_grant_unusable",
          grant_reason: meta["grant_reason"],
          until: parse_until(meta["until"])
        }

        from_error(error, payer, runtime)

      decoded ->
        text = failure_text(decoded, data)
        classify(text, payer, runtime)
    end
  end

  def from_failure(_data, _payer, _runtime), do: nil

  defp failure_text({:ok, %{} = meta}, _data),
    do:
      Enum.map_join(
        ~w(message reason error),
        " ",
        &if(is_binary(meta[&1]), do: meta[&1], else: "")
      )

  defp failure_text(_decoded, data), do: data

  defp classify(text, payer, runtime) do
    cond do
      Regex.match?(@quota, text) ->
        build(
          "credential_exhausted",
          "@#{payer.login}'s #{connection_label(payer, runtime)} is out of quota",
          payer,
          until_in(text),
          nil,
          sanitize(text)
        )

      Regex.match?(@auth, text) ->
        build(
          "credential_rejected",
          "@#{payer.login}'s #{connection_label(payer, runtime)} stopped working",
          payer,
          nil,
          nil,
          sanitize(text)
        )

      true ->
        nil
    end
  end

  @doc """
  Observe a settled turn on a creator-billed track's thread: a failed turn
  whose failure is the payer's credential pauses that harness.

  Runs once per turn, from `Ravix.Tracks.Settlement`'s classification. A
  turn that failed more than half an hour ago is history, not news.
  """
  @spec observe_turn(Track.t(), Project.t(), String.t(), [map()], DateTime.t()) :: :ok
  def observe_turn(track, project, runtime, events, now \\ DateTime.utc_now())

  def observe_turn(%Track{} = track, %Project{} = project, runtime, events, now)
      when is_binary(runtime) do
    events = Enum.map(events, &Event.from/1)

    with true <- Track.creator_billed?(track),
         %Event{} = event <- Enum.find(Enum.reverse(events), &failed_turn?/1),
         true <- recent?(event, now),
         {:ok, payer} <- payer(track, project),
         %{} = pause <- from_failure(event.data, payer, runtime) do
      pause(track, runtime, pause)
    else
      _ -> :ok
    end
  end

  def observe_turn(_track, _project, _runtime, _events, _now), do: :ok

  defp failed_turn?(event),
    do: Event.failed_stage?(event) and event.stage in ["turn", "provision"]

  defp recent?(event, now) do
    case event.ts do
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, at, _} -> DateTime.diff(now, at) <= @recent_failure_seconds
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "What everybody on the track is shown: `Paused: <reason>[ until <time>].[ <detail>]`."
  @spec message(pause()) :: String.t()
  def message(%{"reason" => reason} = pause) do
    until =
      case parse_until(pause["until"]) do
        %DateTime{} = at -> " until " <> Calendar.strftime(at, "%b %-d, %H:%M UTC")
        nil -> ""
      end

    case pause["detail"] do
      detail when is_binary(detail) and detail != "" ->
        "Paused: #{reason}#{until}. #{detail}"

      _ ->
        "Paused: #{reason}#{until}."
    end
  end

  defp build(code, reason, payer, until, grant_reason, detail \\ nil) do
    %{
      "code" => code,
      "reason" => reason,
      "until" => until && DateTime.to_iso8601(until),
      "grant_reason" => grant_reason,
      "detail" => detail,
      "payer" => payer.id,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp parse_until(%DateTime{} = at), do: at

  defp parse_until(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp parse_until(_), do: nil

  # A reset time the runtime's own text carries: Claude Code's
  # `usage limit reached|<unix seconds>`, or an ISO 8601 time. Only a time in
  # the future and within a week and a day; never one made up.
  defp until_in(text) do
    now = DateTime.utc_now()

    candidate =
      case Regex.run(~r/\|(\d{10})\b/, text) do
        [_, seconds] ->
          DateTime.from_unix!(String.to_integer(seconds))

        nil ->
          case Regex.run(
                 ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})/,
                 text
               ) do
            [iso] -> parse_until(iso)
            nil -> nil
          end
      end

    with %DateTime{} = at <- candidate,
         diff when diff > 0 and diff <= @max_until_seconds <- DateTime.diff(at, now) do
      DateTime.truncate(at, :second)
    else
      _ -> nil
    end
  end

  # The runtime's words, short, on one line, with anything shaped like a key
  # or a bearer token removed. It is shown to everybody on the track.
  defp sanitize(text) do
    text
    |> String.replace(~r/[[:cntrl:]]+/u, " ")
    |> String.replace(~r/Bearer\s+\S+/i, "Bearer [redacted]")
    |> String.replace(~r/\b(sk|pk|rk)-[A-Za-z0-9_\-]{8,}/, "[redacted]")
    |> String.replace(~r/[A-Za-z0-9_\-]{32,}/, "[redacted]")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 240)
  end

  @doc """
  Which of the payer's connections a harness runs on, from their own row
  rather than a provider read: Claude Code prefers the subscription token
  when a set holds both, and a ChatGPT subscription outranks an OpenAI key.
  """
  @spec connection_label(User.t(), String.t()) :: String.t()
  def connection_label(%User{credential_connected_at: stamps}, runtime) do
    agent = agent_of(runtime)
    stamps = if is_map(stamps), do: stamps, else: %{}
    subscription? = Map.has_key?(stamps, agent <> ":subscription")

    case {agent, subscription?} do
      {"claude", true} -> "Claude subscription"
      {"claude", false} -> "Anthropic API key"
      {"codex", true} -> "ChatGPT subscription"
      {"codex", false} -> "OpenAI API key"
      _ -> "#{AgentName.label(runtime)} connection"
    end
  end

  defp agent_of(runtime) when runtime in ["claude", "claude-code"], do: "claude"
  defp agent_of(runtime), do: runtime

  defp payer_gone,
    do:
      {:error,
       {:conflict, "payer_unavailable",
        "This track's creator pays for its agent, and their account is gone. Nobody else's is used instead."}}
end
