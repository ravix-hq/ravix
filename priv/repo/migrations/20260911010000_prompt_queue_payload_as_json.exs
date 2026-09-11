defmodule Ravix.Repo.Migrations.PromptQueuePayloadAsJson do
  @moduledoc """
  The queued prompt as JSON the database understands, and its image count.

  `prompt_queue.payload` was `text` holding a JSON string. Reading a field of
  it meant casting in the query -- `NULLIF(?, '')::jsonb->>'prompt'` for the
  panel's summary, and `jsonb_array_length(NULLIF(?, '')::jsonb->'images')`
  for its count -- and the delivery path paid a `Jason.decode!/1` per row.
  The `NULLIF` is there because a delivered row releases its bytes by being
  set to the empty string, which is not JSON, so every read had to defend
  against a sentinel the same column used for "no payload".

  `body` is `jsonb`: Postgres parses it once, on write. `image_count` is a
  column, because the panel wants the number and not the images, and a
  count that survives the release of the bytes it counted is the honest
  thing to show next to "delivered". Releasing the bytes is `NULL` now
  rather than `''`.

  ## Expand

  A new column beside the old one, backfilled, with the release writing both.
  The previous release reads `payload` and nothing else and keeps working.
  Dropping `payload` is a later migration, after this one has been
  everywhere; this cannot be a type change on the column itself, because a
  `jsonb` read through the old release's `field :payload, :string` comes back
  as a map and every `Jason.decode!/1` on it raises.
  """
  use Ecto.Migration

  def up do
    alter table(:prompt_queue) do
      add :body, :map
      add :image_count, :integer
    end

    flush()

    # An empty payload is a released one, and stays released: NULL body,
    # and whatever it was counted as at the time. A row that is not JSON at
    # all has never existed here -- `enqueue/5` is the only writer and it
    # writes `Jason.encode!/1` -- but `NULLIF` costs nothing and the
    # alternative is a migration that fails on one bad row.
    execute("""
    UPDATE #{prefix()}.prompt_queue SET
      body        = NULLIF(payload, '')::jsonb,
      image_count = COALESCE(jsonb_array_length(NULLIF(payload, '')::jsonb->'images'), 0)
    """)

    alter table(:prompt_queue) do
      modify :image_count, :integer, null: false, default: 0
    end
  end

  def down do
    alter table(:prompt_queue) do
      remove :body
      remove :image_count
    end
  end
end
