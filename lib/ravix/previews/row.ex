defmodule Ravix.Previews.Row do
  @moduledoc """
  A track's preview record, the `PreviewRow` of `preview-store.ts`.

  The whole record lives in the `row` jsonb column of `previews` and is
  read and written as a unit; `hostname`, `sprite` and `port` are also real
  columns so the database can enforce uniqueness. This struct is the typed
  view of that document, and `decode/1` and `encode/1` are the only places
  that know how it is spelled on disk.

  ## The `row` keys

  Snake case, one per field of this struct:

    * `track_id`, `hostname`, `service` (`sy-<hostname>`, the Sprites service name)
    * `config`: `nil` or `%{"directory", "command", "readiness_path"}`, the
      track's override of the project default
    * `applied_config`: the JSON the running service was defined from, or `nil`
    * `sandbox_id`, `sprite`, `port`: where the service is, once allocated
    * `desired`: `"running"` or `"stopped"`; `state`: `"stopped"`,
      `"starting"`, `"ready"` or `"failed"`
    * `generation`: bumped by every change of intent, so an operation that
      began under an older number publishes nothing
    * `last_activity`, `lease_until`, `started_at`: milliseconds since the epoch
    * `error`, `logs`, `unavailable`: what the track page shows
    * `cleanup`: the track or project is gone and the service must be deleted
    * `stop_pending`: a stop that did not reach Sprites, retried by the reconciler

  Rows the TypeScript wrote (`trackId`, `readinessPath`) decode too.
  """

  @type state :: :stopped | :starting | :ready | :failed
  @type desired :: :running | :stopped
  @type config :: %{directory: String.t(), command: String.t(), readiness_path: String.t()}

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

  @doc "The struct for a stored `row` document."
  @spec decode(map()) :: t()
  def decode(map) when is_map(map) do
    map = normalize_keys(map)

    %__MODULE__{
      track_id: map["track_id"],
      hostname: map["hostname"],
      config: decode_config(map["config"]),
      applied_config: map["applied_config"],
      sandbox_id: map["sandbox_id"],
      sprite: map["sprite"],
      port: map["port"],
      service: map["service"] || "sy-" <> (map["hostname"] || ""),
      desired: atom(map["desired"], [:running, :stopped], :stopped),
      state: atom(map["state"], [:stopped, :starting, :ready, :failed], :stopped),
      generation: map["generation"] || 0,
      last_activity: map["last_activity"] || 0,
      lease_until: map["lease_until"] || 0,
      started_at: map["started_at"] || 0,
      error: map["error"],
      logs: map["logs"] || "",
      cleanup: map["cleanup"] == true,
      stop_pending: map["stop_pending"] == true,
      unavailable: map["unavailable"]
    }
  end

  @doc "The `row` document for a struct."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = row) do
    %{
      "track_id" => row.track_id,
      "hostname" => row.hostname,
      "config" => encode_config(row.config),
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

  @doc "A stored configuration (`directory`, `command`, `readiness_path`) as an atom-keyed map, or nil."
  @spec decode_config(map() | nil) :: config() | nil
  def decode_config(nil), do: nil

  def decode_config(%{} = map) do
    map = normalize_keys(map)

    %{
      directory: map["directory"],
      command: map["command"],
      readiness_path: map["readiness_path"]
    }
  end

  @doc "A configuration as it is stored."
  @spec encode_config(config() | nil) :: map() | nil
  def encode_config(nil), do: nil

  def encode_config(%{} = config) do
    %{
      "directory" => config.directory,
      "command" => config.command,
      "readiness_path" => config.readiness_path
    }
  end

  @doc "The fingerprint of a configuration, kept as `applied_config` once a service is defined from it."
  @spec fingerprint(config()) :: String.t()
  def fingerprint(config), do: Jason.encode!(encode_config(config))

  @doc "String keys, snake case, whichever spelling the document came in."
  @spec normalize_keys(map()) :: map()
  def normalize_keys(map) do
    Map.new(map, fn {key, value} -> {key |> to_string() |> Macro.underscore(), value} end)
  end

  defp atom(value, allowed, default) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end
end
