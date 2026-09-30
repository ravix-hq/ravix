defmodule Ravix.Repo.Migrations.AddThreadReplyExcerpts do
  use Ecto.Migration

  # RAV-66, expand only: the opening of a thread's newest reply, for the
  # Inbox card, and when that reply settled. Both nullable; the previous
  # release neither reads nor writes them, and a thread whose reply was never
  # seen keeps nil until settlement or a read fills it in.
  def change do
    alter table(:threads) do
      add :reply_excerpt, :text
      add :reply_at, :utc_datetime_usec
    end
  end
end
