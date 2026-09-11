defmodule Ravix.Previews.Row do
  @moduledoc """
  What a track's preview is meant to be doing, and where.

  The working shape the previews pass around, and the typed view of
  `Ravix.Previews.Preview`, which is one column per field:

    * `track_id`, `hostname`, `service` (`sy-<hostname>`, the Sprites service name)
    * `config`: `nil` or a `Ravix.Previews.Config`, the track's override of
      the project default
    * `applied_config`: the fingerprint the running service was defined from, or `nil`
    * `sandbox_id`, `sprite`, `port`: where the service is, once allocated
    * `desired`: `:running` or `:stopped`; `state`: `:stopped`, `:starting`,
      `:ready` or `:failed`
    * `generation`: bumped by every change of intent, so an operation that
      began under an older number publishes nothing
    * `last_activity`, `lease_until`, `started_at`: milliseconds since the epoch
    * `error`, `logs`, `unavailable`: what the track page shows
    * `cleanup`: the track or project is gone and the service must be deleted
    * `stop_pending`: a stop that did not reach Sprites, retried by the reconciler

  This was the `PreviewRow` of `preview-store.ts`, and until the migration
  `PreviewsIntoColumns` it was stored the way that file stored it: all
  nineteen fields in one `row` jsonb document, read and written as a unit.
  `encode/1` is what remains of that, written alongside the columns until the
  release that reads the document is gone.

  `config` is still a map on disk, on this row and on a project's default,
  because it is one value rather than three: nil, or all three fields. In
  memory it is a `Ravix.Previews.Config`, and `Ravix.Previews.Config.Type`
  is the boundary between the two --- which is why nothing here converts it,
  and `encode/1` below has to, because the `row` document is a plain `:map`
  column that Ecto applies no type to.
  """

  alias Ravix.Previews.Config

  @type state :: :stopped | :starting | :ready | :failed
  @type desired :: :running | :stopped
  @type config :: Config.t()

  @type t :: %__MODULE__{
          track_id: String.t(),
          hostname: String.t(),
          config: config() | nil,
          applied_config: String.t() | nil,
          sandbox_id: String.t() | nil,
          sprite: String.t() | nil,
          port: pos_integer() | nil,
          service: String.t(),
          desired: desired(),
          state: state(),
          generation: integer(),
          last_activity: integer(),
          lease_until: integer(),
          started_at: integer(),
          error: String.t() | nil,
          logs: String.t(),
          cleanup: boolean(),
          stop_pending: boolean(),
          unavailable: String.t() | nil
        }

  alias Ravix.Previews.Preview

  defstruct track_id: nil,
            hostname: nil,
            config: nil,
            applied_config: nil,
            sandbox_id: nil,
            sprite: nil,
            port: nil,
            service: nil,
            desired: :stopped,
            state: :stopped,
            generation: 0,
            last_activity: 0,
            lease_until: 0,
            started_at: 0,
            error: nil,
            logs: "",
            cleanup: false,
            stop_pending: false,
            unavailable: nil

  @doc "The stopped record `ensure` writes for a track that has no preview yet."
  @spec new(String.t()) :: t()
  def new(track_id) do
    hostname = "t-" <> String.replace(Ecto.UUID.generate(), "-", "")
    %__MODULE__{track_id: track_id, hostname: hostname, service: "sy-" <> hostname}
  end

  @doc """
  The struct for a stored row.

  No defaulting: every field is a column the database guarantees. `desired`
  and `state` arrive as atoms because `Ecto.Enum` and a `CHECK` have already
  agreed they are one of the set.
  """
  @spec from_preview(Preview.t()) :: t()
  def from_preview(%Preview{} = preview) do
    %__MODULE__{
      track_id: preview.track_id,
      hostname: preview.hostname,
      config: preview.config,
      applied_config: preview.applied_config,
      sandbox_id: preview.sandbox_id,
      sprite: preview.sprite,
      port: preview.port,
      service: preview.service,
      desired: preview.desired,
      state: preview.state,
      generation: preview.generation,
      last_activity: preview.last_activity,
      lease_until: preview.lease_until,
      started_at: preview.started_at,
      error: preview.error,
      logs: preview.logs,
      cleanup: preview.cleanup,
      stop_pending: preview.stop_pending,
      unavailable: preview.unavailable
    }
  end

  @doc "The columns for a struct."
  @spec to_attrs(t()) :: map()
  def to_attrs(%__MODULE__{} = row) do
    %{
      track_id: row.track_id,
      hostname: row.hostname,
      service: row.service,
      sprite: row.sprite,
      port: row.port,
      sandbox_id: row.sandbox_id,
      config: row.config,
      applied_config: row.applied_config,
      desired: row.desired,
      state: row.state,
      generation: row.generation,
      last_activity: row.last_activity,
      lease_until: row.lease_until,
      started_at: row.started_at,
      error: row.error,
      logs: row.logs,
      cleanup: row.cleanup,
      stop_pending: row.stop_pending,
      unavailable: row.unavailable
    }
  end

  @doc """
  The `row` document for a struct.

  Expand-phase only. The columns are the record now; this is written
  alongside them so a previous release, which reads `row` and nothing else,
  keeps working until it is gone. The migration that drops the column takes
  this with it.
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = row) do
    %{
      "track_id" => row.track_id,
      "hostname" => row.hostname,
      "config" => row.config && Config.to_stored(row.config),
      "applied_config" => row.applied_config,
      "sandbox_id" => row.sandbox_id,
      "sprite" => row.sprite,
      "port" => row.port,
      "service" => row.service,
      "desired" => Atom.to_string(row.desired),
      "state" => Atom.to_string(row.state),
      "generation" => row.generation,
      "last_activity" => row.last_activity,
      "lease_until" => row.lease_until,
      "started_at" => row.started_at,
      "error" => row.error,
      "logs" => row.logs,
      "cleanup" => row.cleanup,
      "stop_pending" => row.stop_pending,
      "unavailable" => row.unavailable
    }
  end

  @doc "The fingerprint of a configuration, kept as `applied_config` once a service is defined from it."
  @spec fingerprint(config()) :: String.t()
  def fingerprint(config), do: Jason.encode!(Config.to_stored(config))

  @doc "String keys, snake case, whichever spelling the document came in."
  @spec normalize_keys(map()) :: map()
  def normalize_keys(map) do
    Map.new(map, fn {key, value} -> {key |> to_string() |> Macro.underscore(), value} end)
  end
end
