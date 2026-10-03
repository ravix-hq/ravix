defmodule Ravix.Projects.RuntimeAgent do
  @moduledoc "A project's additional runtime, reserved before its provider create is sent."
  use Ecto.Schema

  @primary_key false
  schema "project_runtime_agents" do
    field :project_id, :string, primary_key: true
    field :resource_id, :string
    field :runtime, :string, primary_key: true
    field :agent_id, :string
    field :credential_set_id, :string
  end
end
