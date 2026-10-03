defmodule Ravix.Tracks.Sandbox.CloneTokens do
  @moduledoc """
  A fresh clone token for every turn still running, before its own expires.

  An installation token lives an hour and is minted as a turn is prepared
  (`Ravix.Tracks.Sandbox.Maintenance.prepare/3`), so a turn that runs past
  the hour used to lose GitHub halfway: `git push` failed and `gh` answered
  401 (RAV-124). The machine never holds the token. Fountain's egress broker
  attaches it in flight from rules it reads per connection, and since
  managoat/fountain#2548 a vault write rewrites the running conversation's
  rules in place, so a value written here reaches the turn's next push.

  Every tick lists Fountain's conversations, keeps the running ones that
  belong to an open track with a repository, and writes a new token into
  each distinct vault behind them: the track's own copy on a dedicated
  machine, the project's on a shared one. Run at a shorter interval than the
  token lives, every token a turn can reach has at least
  `lifetime - interval` left, with no record of when it was minted. A
  turn that is idle or ended in the meantime gets a token it does not use,
  which is the whole cost of not keeping one.

  One instance runs this (`Ravix.Cluster.Singleton`); a second running it
  would mint twice and harm nothing. A failure is logged with the vault and
  nothing else, and the next tick tries again; the turn-start refresh and
  `Ravix.Tracks.AgentFailure.github_notice/2` remain for whatever slips past.
  """
  use GenServer

  require Logger

  alias Ravix.Fountain
  alias Ravix.Projects.{Machine, Project}
  alias Ravix.Tracks.Track

  # Twenty minutes against a sixty-minute token: two ticks may be missed
  # (a deploy, a slow GitHub) before a running turn's token lapses.
  @interval :timer.minutes(20)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  One pass: refresh the vault of every running conversation's track. Returns
  the vault ids it wrote, for the caller that wants to know.
  """
  @spec tick(Fountain.Client.t()) :: {:ok, [String.t()]} | {:error, term()}
  def tick(client \\ Fountain.client()) do
    with {:ok, conversations} <- Fountain.list_conversations(client) do
      running = for %{status: :running, id: id} <- conversations, is_binary(id), do: id

      # ownership: no door -- no person is behind a token refresh. Fountain
      # reported these conversations running, and a token goes only to the
      # vault the track's own turn preparation (`Maintenance.prepare/3`) writes.
      written =
        running
        |> Ravix.Tracks.Store.open_tracks_by_conversations()
        |> Enum.flat_map(&target/1)
        |> Enum.uniq_by(& &1.vault_id)
        |> Enum.filter(&refresh(client, &1))
        |> Enum.map(& &1.vault_id)

      {:ok, written}
    end
  end

  defp target(%Track{} = track) do
    # ownership: no door -- the track's own row names its project; see `tick/1`.
    # A track on a consolidated project runs on its own resource's repository,
    # installation and vault, as `Ravix.Tracks.Sandbox.Store.context/1` binds it.
    project =
      track.project_id
      |> Ravix.Projects.Store.get_project()
      |> Ravix.Projects.Store.for_track(track)

    case project do
      %Project{repo_full_name: repo, installation_id: installation} = project
      when is_binary(repo) and repo != "" and is_integer(installation) ->
        case vault(track, project) do
          id when is_binary(id) and id != "" -> [%{vault_id: id, installation_id: installation}]
          _ -> []
        end

      _ ->
        []
    end
  end

  # The vault `Maintenance.prepare/3` refreshes for the same track.
  defp vault(%Track{sandbox_layout: :dedicated, vault_id: id}, _project), do: id
  defp vault(_track, %Project{vault_id: id}), do: id

  defp refresh(client, target) do
    case Machine.refresh_clone_token(target, client) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning(
          "ravix: clone token refresh failed for vault #{target.vault_id}: #{reason_label(reason)}"
        )

        false
    end
  end

  # The kind and the code, never the message: a provider error can quote the
  # request it refused.
  defp reason_label(%{__struct__: module, code: code}), do: "#{inspect(module)} #{code}"
  defp reason_label({:unconfigured, provider}), do: "#{provider} unconfigured"

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    schedule(interval)
    {:ok, interval}
  end

  @impl true
  def handle_info(:tick, interval) do
    tick()
    schedule(interval)
    {:noreply, interval}
  end

  defp schedule(false), do: :ok
  defp schedule(interval), do: Process.send_after(self(), :tick, interval)
end
