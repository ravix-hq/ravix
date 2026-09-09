defmodule Ravix.Previews.GatewayBackend do
  @moduledoc """
  What the preview gateway asks of the rest of Ravix, answered by this
  context: `RavixWeb.PreviewGateway.Backend`, one callback each.

  Configured as `config :ravix, preview_backend: Ravix.Previews.GatewayBackend`.
  Refusals that carry an HTTP status (`assert_open/1`, `destination/1`)
  come back as `%{status, message}` maps through `RavixWeb.Error.from/1`,
  which is what the gateway reads to answer the browser.
  """

  @behaviour RavixWeb.PreviewGateway.Backend

  alias Ravix.Accounts
  alias Ravix.Accounts.Access
  alias Ravix.Previews
  alias Ravix.Previews.{Row, Store}
  alias Ravix.Repo
  alias Ravix.Tracks.Track
  alias RavixWeb.Error

  @impl true
  def resolve_host(name) do
    case Store.by_host(name) do
      %Row{} = row -> {:ok, row}
      nil -> :error
    end
  end

  @impl true
  def assert_open(track_id) do
    case Previews.assert_open(track_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  @impl true
  def preview(track_id), do: Store.get(track_id)

  @impl true
  def get_grant(hash, track_id, kind, consume?),
    do: Store.get_grant(hash, track_id, kind, consume?)

  @impl true
  def session_user(session_hash), do: Accounts.session_user(session_hash)

  @impl true
  def track_access(user, track_id) do
    case Access.track_access(user, track_id) do
      {:ok, %{track: track}} -> {:ok, track}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def allowed?(row, grant) do
    with %{} <- Store.get_grant(grant.hash, row.track_id, grant.kind, false),
         %{} = user <- Accounts.session_user(grant.session_hash),
         {:ok, %{closed_at: nil}} <- track_access(user, row.track_id) do
      not match?(%Row{cleanup: true}, Store.get(row.track_id))
    else
      _ -> false
    end
  end

  @impl true
  def track(track_id), do: Repo.get(Track, track_id)

  @impl true
  def grant_session(grant) do
    case Store.grant(grant) do
      :ok -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def info(track_id), do: Previews.info(track_id)

  @impl true
  def touch(track_id) do
    Previews.touch(track_id)
    :ok
  end

  @impl true
  def start_service(track_id), do: Previews.start_service(track_id)

  @impl true
  def destination(track_id) do
    case Previews.destination(track_id) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  @impl true
  def public_url, do: Ravix.Config.public_url()

  @impl true
  def previews_config, do: Ravix.Config.previews()

  @impl true
  def sprites_config, do: Ravix.Config.sprites()
end
