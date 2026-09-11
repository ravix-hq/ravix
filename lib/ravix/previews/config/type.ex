defmodule Ravix.Previews.Config.Type do
  @moduledoc """
  The `previews.config` and `preview_defaults.config` columns, as Ecto reads
  and writes them.

  A custom `Ecto.Type` over a `:map` column, so loading a preview row gives a
  `Ravix.Previews.Config` and saving one stores the three string keys it has
  always stored. The conversion used to be `Ravix.Previews.Row.decode_config/1`
  and `encode_config/1`, called by hand at five places: twice in `Row` and
  three times in `Ravix.Previews.Store`. A sixth reader had only to forget.

  ## Why not `embeds_one`

  Because the column must not change. The app runs on more than one instance
  (ADR 0003) and a release that has not been replaced yet still reads
  `config` the way it always did, so `embeds_one` --- which would add its own
  `id` and decide its own key spelling --- is not available until that release
  is gone.

  A custom type is, and this is the difference worth stating: `dump/1`
  answers the same `%{"directory" => _, "command" => _, "readiness_path" => _}`
  that `encode_config/1` answered, so the jsonb on disk is byte for byte what
  it was. Nothing about expand/contract changes; only which code does the
  conversion. `Ravix.Previews.Row.fingerprint/1` is the proof it has to be
  identical — the fingerprint of the stored map is `applied_config`, and a
  deploy that spelled it differently would redefine every running service.

  ## Why `cast/1` does not validate

  Validation is `Ravix.Previews.Config.parse/1`'s, at the three boundaries
  where somebody typed or sent the value: the track's preview form, the
  project's defaults form, and the agent's preview helper. By the time a
  configuration reaches a changeset it has been through one of those.

  So `cast/1` is about representation and nothing else. A row written by an
  older release, or one whose fields a later version of this app would now
  refuse, loads and saves as it is. Re-checking it here would mean a preview
  that cannot be stopped because the configuration it was started with no
  longer passes — a row to notice, not one to quietly correct on the way
  past.
  """

  use Ecto.Type

  alias Ravix.Previews.Config

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(%Config{} = config), do: {:ok, config}
  def cast(%{} = stored), do: {:ok, Config.from_stored(stored)}
  def cast(_other), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}
  def load(%{} = stored), do: {:ok, Config.from_stored(stored)}
  def load(_other), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}
  def dump(%Config{} = config), do: {:ok, Config.to_stored(config)}
  def dump(_other), do: :error
end
