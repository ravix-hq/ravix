defmodule Ravix.Previews.Config do
  @moduledoc """
  The project run script and per-track override.

  Directory and command are required. An optional HTTP readiness path enables
  the preview; without one, readiness means the managed process is running.
  An optional stop command runs before the service's process group is stopped.

  The existing `preview_defaults.config` and `previews.config` maps remain the
  single source of truth. Readers accept legacy three-field maps and expanded
  maps. Writers omit an absent stop command, preserving legacy fingerprints
  and definitions during the expand phase. No table copy or destructive rename
  is needed; the old preview APIs remain compatibility entry points.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ravix.Previews.Row

  @type t :: %__MODULE__{
          directory: String.t(),
          command: String.t(),
          readiness_path: String.t() | nil,
          stop_command: String.t() | nil
        }

  # `Ravix.Previews.Agent` answers the preview helper with the configuration
  # in its JSON, and `RavixWeb.PreviewController.agent/2` hands that straight
  # to `json/2`. The three keys are the three this always sent as a map.
  @derive {Jason.Encoder, only: [:directory, :command, :readiness_path, :stop_command]}

  @primary_key false
  embedded_schema do
    field :directory, :string
    field :command, :string
    field :readiness_path, :string
    field :stop_command, :string
  end

  @fields [:directory, :command, :readiness_path, :stop_command]

  @directory_message "Choose a relative app directory inside this track."
  @command_message "Supply a startup command that honors $PORT and fails if that port is occupied."
  @readiness_message "Readiness must be an HTTP path on this app, such as /health."

  @doc """
  Parse `attrs` into a configuration, or refuse with the changeset carrying
  an error on each field that is wrong.

  `nil` is the answer "no configuration", which is a real value at both
  levels and not a refusal.
  """
  @spec parse(term()) :: {:ok, t() | nil} | {:error, Ecto.Changeset.t()}
  def parse(nil), do: {:ok, nil}

  def parse(%__MODULE__{} = config), do: {:ok, config}

  def parse(%{} = attrs) do
    attrs
    |> changeset()
    |> apply_action(:insert)
  end

  # Anything that is not a map and not nil. Cast has no field to blame, so
  # the error goes on the changeset as a whole and reads as the 422 it did
  # before.
  def parse(_other) do
    {:error,
     %__MODULE__{}
     |> change()
     |> add_error(:config, "Supply a preview configuration.")
     |> Map.put(:action, :insert)}
  end

  @doc """
  The changeset for `attrs`, with every field it can refuse refused.

  Deliberately not three `validate_*` helpers over one regular expression
  each: two of these three are about what may be sent to a shell and to a
  sprite's HTTP front, and they are written out so the reason each
  character is excluded stays legible.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    # `empty_values: []` because a blank directory is a real answer here ---
    # it is the track root, and `validate_directory/1` writes it as `"."`.
    # Ecto's default drops a whitespace-only string as though the field had
    # not been sent, which would turn "the root" into "no directory at all"
    # and refuse a form somebody filled in correctly.
    %__MODULE__{}
    |> cast(Row.normalize_keys(attrs), @fields, empty_values: [])
    |> validate_directory()
    |> validate_command()
    |> validate_stop_command()
    |> validate_readiness_path()
  end

  # A relative path inside the track, and nothing that climbs out of it or
  # smuggles a control character into the `cd` that runs it. An empty
  # directory is the track root, spelled the way a shell spells it.
  defp validate_directory(changeset) do
    directory = changeset |> get_field(:directory) |> trim()

    cond do
      not is_binary(directory) -> add_error(changeset, :directory, @directory_message)
      String.length(directory) > 1_000 -> add_error(changeset, :directory, @directory_message)
      String.starts_with?(directory, "/") -> add_error(changeset, :directory, @directory_message)
      ".." in String.split(directory, "/") -> add_error(changeset, :directory, @directory_message)
      control_char?(directory) -> add_error(changeset, :directory, @directory_message)
      directory == "" -> put_change(changeset, :directory, ".")
      true -> put_change(changeset, :directory, directory)
    end
  end

  defp validate_command(changeset) do
    command = changeset |> get_field(:command) |> trim()

    cond do
      not is_binary(command) -> add_error(changeset, :command, @command_message)
      command == "" -> add_error(changeset, :command, @command_message)
      String.length(command) > 8_000 -> add_error(changeset, :command, @command_message)
      String.contains?(command, <<0>>) -> add_error(changeset, :command, @command_message)
      true -> put_change(changeset, :command, command)
    end
  end

  defp validate_stop_command(changeset) do
    command = changeset |> get_field(:stop_command) |> trim()

    cond do
      command in [nil, ""] ->
        put_change(changeset, :stop_command, nil)

      is_binary(command) and byte_size(command) <= 8_000 and not String.contains?(command, <<0>>) ->
        put_change(changeset, :stop_command, command)

      true ->
        add_error(
          changeset,
          :stop_command,
          "Supply a stop command of at most 8,000 bytes without null characters."
        )
    end
  end

  # An absolute path on this app and nothing else. `//` would be a
  # protocol-relative URL, and space, `#` and `\` would each end the path
  # somewhere other than where it reads as ending.
  defp validate_readiness_path(changeset) do
    path = get_field(changeset, :readiness_path)

    cond do
      path in [nil, ""] ->
        put_change(changeset, :readiness_path, nil)

      not is_binary(path) ->
        add_error(changeset, :readiness_path, @readiness_message)

      not String.starts_with?(path, "/") ->
        add_error(changeset, :readiness_path, @readiness_message)

      String.starts_with?(path, "//") ->
        add_error(changeset, :readiness_path, @readiness_message)

      String.length(path) > 1_000 ->
        add_error(changeset, :readiness_path, @readiness_message)

      Regex.match?(~r/[\x00-\x20#\\]/, path) ->
        add_error(changeset, :readiness_path, @readiness_message)

      true ->
        changeset
    end
  end

  @doc """
  A stored configuration as a struct.

  Read back rather than re-validated: these three came out of `changeset/1`
  before they were written, and a row that somehow holds something else is a
  row to notice rather than one to quietly correct on the way past. This was
  `Ravix.Previews.Row.decode_config/1`.
  """
  @spec from_stored(map()) :: t()
  def from_stored(%{} = stored) do
    stored = Row.normalize_keys(stored)

    %__MODULE__{
      directory: stored["directory"],
      command: stored["command"],
      readiness_path: stored["readiness_path"],
      stop_command: stored["stop_command"]
    }
  end

  @doc """
  A configuration as stored: legacy keys plus the optional stop command.

  `Ravix.Previews.Row.fingerprint/1` hashes this, so the key order and
  spelling are load-bearing across a deploy. This was
  `Ravix.Previews.Row.encode_config/1`.
  """
  @spec to_stored(t()) :: map()
  def to_stored(%__MODULE__{} = config) do
    %{
      "directory" => config.directory,
      "command" => config.command,
      "readiness_path" => config.readiness_path
    }
    |> then(fn stored ->
      if config.stop_command,
        do: Map.put(stored, "stop_command", config.stop_command),
        else: stored
    end)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp control_char?(value), do: Regex.match?(~r/[\x00-\x1f]/, value)
end
