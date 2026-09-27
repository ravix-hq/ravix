defmodule Ravix.Repo.Migrations.PinSharedHomeRuntime do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :shared_home_runtime, :text
    end
  end
end
