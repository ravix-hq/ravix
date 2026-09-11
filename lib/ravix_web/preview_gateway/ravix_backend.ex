defmodule RavixWeb.PreviewGateway.RavixBackend do
  @moduledoc """
  What the preview gateway asks of the rest of Ravix, answered by the
  contexts: `RavixWeb.PreviewGateway.Backend`, one callback each.

  Every callback here is a delegation or a translation of a refusal into an
  HTTP one. Nothing in this module reads a row: it is in `lib/ravix_web/`,
  and the row layer is not reachable from there.

  Configured as `config :ravix, preview_backend: RavixWeb.PreviewGateway.RavixBackend`.
  Refusals that carry an HTTP status (`assert_open/1`, `destination/1`)
  come back as `%{status, message}` maps through `RavixWeb.Error.from/1`,
  which is what the gateway reads to answer the browser.
  """

  @behaviour RavixWeb.PreviewGateway.Backend

  alias Ravix.Accounts
  alias Ravix.Accounts.Access
  alias Ravix.Previews
  alias RavixWeb.Error

  @impl true
  defdelegate resolve_host(name), to: Previews, as: :by_host

  @impl true
  def assert_open(track_id) do
    case Previews.assert_open(track_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  @impl true
  defdelegate preview(track_id), to: Previews, as: :row

  @impl true
  defdelegate get_grant(hash, track_id, kind, disposition), to: Previews, as: :grant_by_hash

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
  defdelegate allowed?(row, grant), to: Previews

  @impl true
  defdelegate track(track_id), to: Previews

  @impl true
  defdelegate grant_session(grant), to: Previews, as: :record_grant

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
