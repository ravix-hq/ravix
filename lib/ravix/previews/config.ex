defmodule Ravix.Previews.Config do
  @moduledoc """
  What a track's preview runs, and where: a schema that refuses its own
  fields.

  Three values, all three or none: the relative directory inside the track,
  the startup command, and the HTTP path that answers when the app is up.
  A track has one as an override, a project has one as a default, and
  `nil` at either level means "use the one below".

  ## Why a changeset

  This was `parsePreviewConfig` in `server/previews.ts`, and it was ported
  the shape it had: a `cond` over three hand-written predicates, answering
  `{:unprocessable, code, message}` with a *string code* naming the field
  it was about. `RavixWeb.Live.Form` then held a second table turning that
  code back into the field --- `"preview_directory" => :directory` --- so
  the sentence could land beside the input somebody typed it in.

  Two things were wrong with that beyond the bookkeeping. A `cond` answers
  once, so a form with all three boxes wrong was corrected one box per
  round trip. And the two tables are a pairing nothing enforces: a code
  renamed here and not there stops being about a field at all, and the
  sentence silently goes back to being a toast.

  A changeset is what Ecto already has for this. `cast/4` names the fields,
  every validation runs, and `RavixWeb.Live.Form.refuse/2` puts each error
  on the field it is already attached to. There is no second table.

  ## What is not stored here

  The `previews.config` and `preview_defaults.config` columns stay `:map`
  and keep the three string keys they have always had. This is the working
  struct, converted at `Ravix.Previews.Row.decode_config/1` and
  `encode_config/1` --- the same one-boundary rule the provider shapes
  follow --- rather than an `embeds_one`, because the app runs on more than
  one instance (ADR 0003) and a release that has not been replaced yet is
  still reading that column the way it always did.

  `Row.fingerprint/1` encodes the same three-key map it always encoded, so
  a deploy does not redefine every running service for want of a matching
  `applied_config`.

  ## Keys

  `changeset/1` takes whichever spelling the caller has. The track page
  submits `readiness_path`, and the agent's preview helper is shown
  `readinessPath` in the JSON example it is given
  (`Ravix.Previews.Agent`), so both arrive in practice. That normalisation
  is the wire boundary doing its job and belongs here, at the one place
  the keys are cast, rather than in the three callers.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ravix.Previews.Row

  @type t :: %__MODULE__{
          directory: String.t(),
          command: String.t(),
          readiness_path: String.t()
        }

  # `Ravix.Previews.Agent` answers the preview helper with the configuration
  # in its JSON, and `RavixWeb.PreviewController.agent/2` hands that straight
  # to `json/2`. The three keys are the three this always sent as a map.
  @derive {Jason.Encoder, only: [:directory, :command, :readiness_path]}

  @primary_key false
  embedded_schema do
    field :directory, :string
    field :command, :string
    field :readiness_path, :string
  end

  @fields [:directory, :command, :readiness_path]

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

  # An absolute path on this app and nothing else. `//` would be a
  # protocol-relative URL, and space, `#` and `\` would each end the path
  # somewhere other than where it reads as ending.
  defp validate_readiness_path(changeset) do
    path = get_field(changeset, :readiness_path)

    cond do
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

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp control_char?(value), do: Regex.match?(~r/[\x00-\x1f]/, value)
end
