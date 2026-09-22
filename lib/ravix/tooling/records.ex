defmodule Ravix.Tooling.Client do
  @moduledoc "A registered public OAuth client. Names are self-asserted."
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "tooling_clients" do
    field :name, :string
    field :redirect_uris, {:array, :string}
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Ravix.Tooling.Grant do
  @moduledoc "Revocable user consent for one client, resource and set of scopes."
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "tooling_grants" do
    field :user_id, :string
    field :client_id, :string
    field :resource, :string
    field :scopes, {:array, :string}
    field :revoked_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Ravix.Tooling.Credential do
  @moduledoc "Hashed authorization codes and tokens; consumed refresh tokens detect replay."
  use Ecto.Schema
  @derive {Inspect, except: [:hash, :challenge]}
  @primary_key {:hash, :string, autogenerate: false}
  schema "tooling_credentials" do
    field :grant_id, :string
    field :kind, :string
    field :redirect_uri, :string
    field :challenge, :string
    field :used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end
end

defmodule Ravix.Tooling.Receipt do
  @moduledoc "A durable claim prevents retrying an ambiguous external mutation."
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "tooling_receipts" do
    field :user_id, :string
    field :client_id, :string
    field :operation, :string
    field :fingerprint, :string
    field :result, :map
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Ravix.Tooling.Task do
  @moduledoc "One delegated prompt, correlated with Fountain by its queue request ID."
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "tooling_tasks" do
    field :user_id, :string
    field :client_id, :string
    field :track_id, :string
    field :fingerprint, :string
    field :state, :string, default: "TASK_STATE_SUBMITTED"
    field :turn_id, :string
    field :cursor, :integer
    field :result, :string, default: ""
    timestamps(type: :utc_datetime_usec)
  end
end
