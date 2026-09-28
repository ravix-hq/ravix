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
    field :last_used_at, :utc_datetime_usec
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
    field :queue_status, :any, virtual: true
    field :status_message, :string, virtual: true
    field :reconciled_at, :utc_datetime_usec
    field :failure_code, :string
    field :failure_message, :string
    field :error_code, :string, virtual: true
    field :setup_failed, :boolean, virtual: true, default: false
    field :blocked, :boolean, virtual: true, default: false
    field :turn_id, :string
    field :cursor, :integer
    field :cursor_conversation_id, :string
    field :result, :string, default: ""
    field :reply_compacted, :boolean, default: false
    field :reply_size, :integer, default: 0
    field :reply_bytes, :integer, default: 0
    field :failure_evidence, :map, default: %{}
    field :reply_events, {:array, :map}, default: []
    field :reply_prefix, :string, default: ""
    field :turn_seen, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Ravix.Tooling.ThreadCheckpoint do
  @moduledoc "Durable event high-water mark and backstop cadence for task receipts on one thread."
  use Ecto.Schema
  @primary_key false
  schema "tooling_thread_checkpoints" do
    field :id, :string, primary_key: true
    field :conversation_id, :string, primary_key: true
    field :cursor, :integer
    field :signature, :string
    field :unchanged, :integer, default: 0
    field :next_due_at, :utc_datetime_usec
    field :generation, :integer, default: 0
  end
end

defmodule Ravix.Tooling.ReplyChunk do
  @moduledoc "Append-only bounded reply fragments, committed with the receipt cursor."
  use Ecto.Schema
  @primary_key false
  schema "tooling_reply_chunks" do
    field :task_id, :string, primary_key: true
    field :cursor, :integer, primary_key: true
    field :body, :string
  end
end
