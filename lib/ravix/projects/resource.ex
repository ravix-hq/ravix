defmodule Ravix.Projects.Resource do
  @moduledoc "Provider resources retained when repository projects are consolidated."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "project_resources" do
    field :project_id, :string
    field :user_id, :string
    field :agent_id, :string
    field :environment_id, :string
    field :vault_id, :string
    field :runtime, :string
    field :model, :string
    field :credential_set_id, :string
    field :home_runtime, :string
    field :shared_home_runtime, :string
    field :runtime_agents_retiring, :boolean, default: false
    field :secrets_generation, :integer, default: 0
    field :secrets_pending, :boolean, default: false
    field :shared_machine_retiring, :boolean, default: false
    field :rev, :integer, default: 1
    field :instructions, :string, default: ""
    field :installation_id, :integer
    field :repo_full_name, :string
    field :repo_private, :boolean, default: false
    field :default_branch, :string
    field :created_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    field :deletion_requested_at, :utc_datetime_usec
  end

  # Authorization always uses the surviving project; only machine settings
  # and the payer follow the original resource binding.
  def bind(project, resource) do
    fields =
      resource
      |> Map.from_struct()
      |> Map.drop([
        :__meta__,
        :id,
        :project_id,
        :user_id,
        :created_at,
        :archived_at,
        :deletion_requested_at
      ])

    struct(
      project,
      Map.merge(fields, %{resource_id: resource.id, resource_owner_id: resource.user_id})
    )
  end
end
