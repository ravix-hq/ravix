defmodule Ravix.Repo.Migrations.AddThreadSessionConfig do
  @moduledoc """
  RAV-52: a thread's ACP session config choice (Fountain ADR 0062), sent as
  each prompt's `session_config`, and a person's default for new threads.

  `threads.session_config` maps the runtime's own option ids to values
  (`{"effort": "high", "fast": true}` on claude, `{"reasoning_effort": ...,
  "fast-mode": ...}` on codex). `users.preferred_session_config` holds one
  such map per runtime. Fountain does not keep a prompt's options, so Ravix
  is where the choice lives.

  Expand only: both columns default to an empty map and nothing the release
  still serving reads them. A constant default does not rewrite the table.
  """
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :session_config, :map, null: false, default: %{}
    end

    alter table(:users) do
      add :preferred_session_config, :map, null: false, default: %{}
    end
  end
end
