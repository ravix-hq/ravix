defmodule Ravix.Previews.Agent do
  @moduledoc """
  The agent's way to drive its track's preview: `server/agent-previews.ts`.

  Before each user turn is delivered, `prepare/1` installs a small shell
  helper at `/home/sprite/.ravix/previews/<track-id>.sh` inside the sprite
  and returns the instructions the prompt is prefixed with. The helper
  carries a two-hour bearer credential whose hash is the one agent grant
  per track; the credential stays outside the checkout and transcript,
  and the helper can only operate its own track's preview: never project
  defaults, never browser tickets.

  `route/3` is the endpoint the helper calls, `POST
  /api/tracks/:id/preview/agent`; it returns tagged refusals for the HTTP boundary to translate.
  """

  alias Ravix.Accounts
  alias Ravix.Accounts.Access
  alias Ravix.Crypto
  alias Ravix.Ids
  alias Ravix.Previews
  alias Ravix.Previews.{Clock, Store}
  alias Ravix.Projects.Project
  alias Ravix.PromptQueue.Item
  alias Ravix.Repo
  alias Ravix.Sprites
  alias Ravix.Tracks.Track

  @start "[ravix preview tools for this turn]"
  @end_ "[/ravix preview tools]"
  @grant_ms 2 * 60 * 60_000
  @actions ~w(configure start restart stop status logs)
  @delivered [:sending, :sent, :unconfirmed]
  @install_timeout_sec 15

  @doc "The marker that opens the injected instructions (`AGENT_PREVIEW_START`)."
  @spec start_marker() :: String.t()
  def start_marker, do: @start

  @doc "The marker that closes them (`AGENT_PREVIEW_END`)."
  @spec end_marker() :: String.t()
  def end_marker, do: @end_

  @doc """
  A prompt as the transcript shows it: the injected instructions removed,
  the person's own words and attribution intact (`visiblePreviewPrompt`).
  """
  @spec visible_prompt(String.t()) :: String.t()
  def visible_prompt(prompt) do
    if String.starts_with?(prompt, @start <> "\n") do
      case :binary.match(prompt, "\n" <> @end_ <> "\n\n") do
        :nomatch ->
          prompt

        {at, _} ->
          binary_part(
            prompt,
            at + byte_size(@end_) + 3,
            byte_size(prompt) - at - byte_size(@end_) - 3
          )
      end
    else
      prompt
    end
  end

  @doc """
  The helper script. The credential stays outside the checkout and
  transcript. The helper can only operate its track's preview, never
  project settings or browser tickets.
  """
  @spec script(String.t(), String.t()) :: String.t()
  def script(url, token) do
    """
    #!/bin/sh
    set -eu
    case "${1:-status}" in
      configure) [ "$#" -eq 2 ] || { echo 'Usage: preview configure <config JSON or null>' >&2; exit 2; }; body='{ "action":"configure", "config":'"$2"'}' ;;
      status|start|restart|stop|logs) body='{ "action":"'"${1:-status}"'" }' ;;
      *) echo 'Commands: configure <JSON>, status, start, restart, stop, logs' >&2; exit 2 ;;
    esac
    exec curl --fail-with-body --silent --show-error --max-time 90 \\
      -H #{Sprites.shq("Authorization: Bearer " <> token)} -H 'Content-Type: application/json' \\
      --data "$body" #{Sprites.shq(url)}
    """
  end

  @doc """
  Install the helper for a prompt about to be delivered and return the
  instructions to prefix it with. An empty string when previews are
  unavailable. Optional preview plumbing must never strand an ordinary
  saved prompt: any failure yields a note telling the agent to continue
  without the helper.
  """
  @spec prepare(%{
          :track_id => String.t(),
          :user_id => String.t(),
          :id => String.t(),
          optional(atom()) => term()
        }) ::
          String.t()
  def prepare(%{track_id: track_id, user_id: user_id, id: prompt_id}) do
    if Previews.unavailable() do
      ""
    else
      track = Repo.get!(Track, track_id)
      project = Repo.get!(Project, track.project_id)

      case install(track, project, user_id, prompt_id) do
        {:ok, path} -> instructions(track, project, path)
        {:error, hash} -> abandon(track, hash)
      end
    end
  end

  defp install(track, project, user_id, prompt_id) do
    with {:ok, %{sandbox_id: sandbox_id}} <- Ravix.Tracks.machine_of(project),
         sprite when is_binary(sprite) <- Ravix.Tracks.sprite_for(sandbox_id) do
      token = Crypto.random_token()
      hash = Crypto.sha256(token)

      grant = %{
        hash: hash,
        track_id: track.id,
        user_id: user_id,
        conversation_id: track.conversation_id,
        prompt_id: prompt_id,
        sandbox_id: sandbox_id,
        sprite: sprite,
        expires: Clock.now_ms() + @grant_ms
      }

      with :ok <- Store.grant_agent(grant),
           {:ok, path} <- write_helper(track, sprite, token),
           %{} <- Store.agent_grant(hash) do
        {:ok, path}
      else
        _ -> {:error, hash}
      end
    else
      _ -> {:error, nil}
    end
  end

  defp write_helper(track, sprite, token) do
    dir = "#{Ids.state_dir()}/previews"
    path = "#{dir}/#{track.id}.sh"

    url =
      "#{Ravix.Config.public_url()}/api/tracks/#{URI.encode(track.id, &URI.char_unreserved?/1)}/preview/agent"

    command =
      "umask 077; mkdir -p #{Sprites.shq(dir)} && printf %s #{Sprites.shq(script(url, token))} > " <>
        "#{Sprites.shq(path <> ".tmp")} && mv #{Sprites.shq(path <> ".tmp")} #{Sprites.shq(path)}"

    case Sprites.exec(Sprites.config(), sprite, ["sh", "-lc", command], @install_timeout_sec) do
      {:ok, %{code: 0}} -> {:ok, path}
      _ -> {:error, :helper_unavailable}
    end
  end

  defp abandon(track, hash) do
    if hash && Store.agent_grant(hash), do: Store.revoke_agent(track.id)

    "#{@start}\nThe preview helper could not be prepared this turn. Continue the requested work; " <>
      "use the track's preview controls if needed.\n#{@end_}"
  end

  defp instructions(track, project, path) do
    public_url = Ravix.Config.public_url()
    domain = Ravix.Config.previews().domain

    example =
      Jason.encode!(%{
        directory: "apps/example",
        command: ~s(npm run dev -- --host 127.0.0.1 --port "$PORT" --strictPort),
        readinessPath: "/"
      })

    Enum.join(
      [
        @start,
        "You can configure this track's live preview with: sh #{Sprites.shq(path)} <command>.",
        "Commands: configure '<config JSON>', start, status, logs, restart, stop. configure null restores the project default.",
        "Config example: #{example}",
        "When asked to set up a live preview, inspect this track's app and dependencies, choose the correct relative directory and startup command, then configure and start it. Poll status until Ready; use logs to fix failures. Do not claim readiness before the server reports it.",
        "The app must honor $PORT, refuse port fallback, and allow hosts under .#{domain}. Keep HMR on the browser's current host/port. Scope other ports and writable data to this track.",
        "Use this helper for managed previews; do not launch a detached dev server or change project defaults. The helper contains a temporary credential: execute it, but do not read, print, copy, or commit it. It expires after two hours and is renewed on the next user turn.",
        "When Ready, direct the user to Open preview on their track: #{public_url}/p/#{project.id}/t/#{track.id}. Browser sign-in stays required.",
        @end_
      ],
      "\n"
    )
  end

  @doc """
  `POST /api/tracks/:id/preview/agent`: what the helper's bearer token may
  do, checked twice around the provider reads because membership can
  change during them and a revoked grant must never be resurrected.
  Returns the track's info plus `track_url`, or a tagged refusal.
  """
  @spec route(String.t(), String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def route(track_id, authorization, body) do
    with {:ok, grant} <- bearer_grant(authorization, track_id),
         {:ok, user} <- grant_user(grant),
         {:ok, %{track: track, project: project}} <- access(user, track_id),
         :ok <- open(track_id),
         :ok <- delivered_turn(track, grant, user),
         :ok <- available(),
         {:ok, action} <- action_of(body),
         :ok <- same_machine(project, grant),
         :ok <- still_granted(grant),
         {:ok, _} <- access(user, track_id),
         :ok <- open(track_id),
         :ok <- turn_still_on(track_id, grant),
         :ok <- perform(action, track_id, body) do
      track_url = "#{Ravix.Config.public_url()}/p/#{project.id}/t/#{track_id}"
      {:ok, Map.put(Previews.info(track_id), :track_url, track_url)}
    end
  end

  defp bearer_grant(authorization, track_id) do
    with [_, token] <- Regex.run(~r/^Bearer ([A-Za-z0-9_-]{20,})$/, authorization || ""),
         %{track_id: ^track_id} = grant <- Store.agent_grant(Crypto.sha256(token)) do
      {:ok, grant}
    else
      _ -> auth_error("Preview helper expired. Send another message to renew it.")
    end
  end

  defp grant_user(grant) do
    case Accounts.get_user(grant.user_id) do
      nil -> auth_error("Preview access ended.")
      user -> {:ok, user}
    end
  end

  defp access(user, track_id) do
    case Access.track_access(user, track_id) do
      {:ok, found} -> {:ok, found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open(track_id) do
    case Previews.assert_open(track_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivered_turn(track, grant, user) do
    prompt = Repo.get_by(Item, id: grant.prompt_id)

    if track.conversation_id == grant.conversation_id and prompt != nil and
         prompt.track_id == track.id and prompt.user_id == user.id and prompt.status in @delivered,
       do: :ok,
       else: auth_error("This preview helper no longer belongs to an active delivered turn.")
  end

  defp available do
    case Previews.unavailable() do
      nil -> :ok
      why -> {:error, {:preview_unavailable, why}}
    end
  end

  defp action_of(body) do
    action = body["action"] || body[:action]

    if is_binary(action) and action in @actions,
      do: {:ok, action},
      else: {:error, {:unprocessable, "preview_action", "Unknown preview helper command."}}
  end

  # Fresh, not memoised: this is the check that the helper's grant still
  # names the machine that is there, and a memo could vouch for one that is gone.
  defp same_machine(project, grant) do
    with {:ok, %{sandbox_id: sandbox_id}} when sandbox_id == grant.sandbox_id <-
           Ravix.Tracks.machine_of(project, fresh: true),
         sprite when sprite == grant.sprite <- Ravix.Tracks.sprite_for(sandbox_id) do
      :ok
    else
      _ ->
        {:error,
         {:conflict, "preview_replaced",
          "The workspace changed. Send another message to renew the helper."}}
    end
  end

  # Membership can change during provider reads. Never resurrect a revoked grant.
  defp still_granted(grant) do
    if Store.agent_grant(grant.hash), do: :ok, else: auth_error("Preview access ended.")
  end

  defp turn_still_on(track_id, grant) do
    prompt = Repo.get_by(Item, id: grant.prompt_id)
    track = Repo.get(Track, track_id)

    if track != nil and track.conversation_id == grant.conversation_id and prompt != nil and
         prompt.status in @delivered,
       do: :ok,
       else: auth_error("This preview helper's turn has ended or changed.")
  end

  defp perform("configure", track_id, body) do
    with {:ok, config} <- Previews.parse_config(body["config"] || body[:config]),
         :ok <- Previews.configure(track_id, config) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp perform(action, track_id, _body) when action in ["start", "restart"] do
    Task.Supervisor.start_child(Ravix.TaskSupervisor, fn ->
      Previews.start_service(track_id, action == "restart")
    end)

    :ok
  end

  defp perform("stop", track_id, _body), do: wrap(Previews.stop_service(track_id))
  defp perform("logs", track_id, _body), do: wrap(Previews.refresh_logs(track_id))
  defp perform(_status, _track_id, _body), do: :ok

  defp wrap(:ok), do: :ok
  defp wrap({:error, reason}), do: {:error, reason}

  defp auth_error(message),
    do: {:error, {:preview_agent_auth, message}}
end
