defmodule Ravix.Tracks.Track do
  @moduledoc """
  Which track is which.

  A row, because a Fountain `channel_id` can say the slug but not who made
  it, from what, or what it is called. Everything else about a track is read
  live: its status, its turn count, whether the machine is up, what is in
  the worktree. Those are questions with a correct answer somewhere else,
  and caching them here is how a UI ends up confidently showing a machine
  that died an hour ago.

  Sandbox ownership is persisted for both layouts. Shared is the database
  default, including inserts from older releases. Dedicated ownership never
  derives from conversation liveness; sandbox_state records lifecycle intent,
  not provider health.

  Setup is another exception: its durable state records Ravix's verified opening
  outcome, attempt budget, retry deadline and worker lease. `opened_at` is set
  only after completion and a worktree check; old accepted-only rows are
  reconciled by `Tracks.Setup` before queued work may be claimed.

  One live track per slug per project: the slug is a directory name on a
  real machine, so two of them is not a naming clash, it is two tracks
  writing to one worktree. The partial unique index `tracks_slug` enforces
  it over rows whose `closed_at` is null.

  `rev` is the project rev this track opened at. A lower one means older
  settings. `origin_kind` is one the database allows and this schema loads,
  so the read side can trust it rather than coercing anything it does not know into
  `blank`; the other `origin_*` columns describe what the track was created
  from.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @origin_kinds ~w(blank branch pr issue plan)a

  # Kinds this release can read but not yet start. A release that starts a
  # new kind is deployed while the previous one still serves, and that one
  # has to load the rows the new one writes: so a kind is readable one
  # release before anything writes it (ADR 0003, expand before contract).
  # `plan` passed through here and is now startable; none is waiting.
  @readable_only_kinds []

  @typedoc "What a track was started from."
  @type origin_kind :: :blank | :branch | :pr | :issue | :plan

  @type t :: %__MODULE__{}

  schema "tracks" do
    belongs_to :project, Ravix.Projects.Project
    field :sandbox_layout, Ecto.Enum, values: [:shared, :dedicated], default: :shared
    field :sandbox_stage, :string
    field :secrets_generation, :integer, default: 0
    field :sandbox_id, :string
    field :sandbox_generation, :integer, default: 0

    field :sandbox_state, Ecto.Enum,
      values: [:provisioning, :ready, :failed, :closing, :terminated]

    field :last_runtime, :string
    field :vault_id, :string
    field :conversation_id, :string
    field :slug, :string
    field :title, :string
    field :branch, :string
    field :branch_reserved, :boolean, default: true
    field :workdir, :string
    field :origin_kind, Ecto.Enum, values: @origin_kinds ++ @readable_only_kinds
    field :origin_base, :string
    field :origin_number, :integer
    field :origin_title, :string
    field :origin_url, :string
    field :origin_plan_id, :string
    field :origin_item_id, :string
    field :rev, :integer, default: 1
    field :setup_state, :string, default: "pending"
    field :setup_attempts, :integer, default: 0
    field :setup_request_id, :string
    field :setup_started_at, :utc_datetime_usec
    field :setup_retry_at, :utc_datetime_usec
    field :setup_error, :string
    field :setup_error_code, :string
    field :setup_lease, :string
    field :setup_lease_until, :utc_datetime_usec
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :created_by_login, :string
    field :created_by, :string
    field :creator_revoked_at, :utc_datetime_usec
    field :visibility, Ecto.Enum, values: [:project, :private], default: :project

    has_many :threads, Ravix.Tracks.Thread
    has_many :prompts, Ravix.PromptQueue.Item
    has_many :members, Ravix.Tracks.TrackMember
    has_many :invites, Ravix.Tracks.TrackInvite
    has_many :reads, Ravix.Tracks.TrackRead
    has_one :link, Ravix.Tracks.TrackLink
    has_one :preview, Ravix.Previews.Preview
  end

  @fields ~w(visibility created_by last_runtime sandbox_layout sandbox_id sandbox_generation sandbox_state vault_id id project_id conversation_id slug title branch branch_reserved workdir origin_kind origin_base
             origin_number origin_title origin_url origin_plan_id origin_item_id rev setup_state setup_attempts setup_request_id setup_started_at setup_retry_at setup_error setup_error_code setup_lease setup_lease_until opened_at closed_at created_at created_by_login)a
  @required ~w(id project_id slug title branch workdir origin_kind rev created_at created_by_login)a

  @doc "The four things a track can be started from."
  @spec origin_kinds() :: [origin_kind()]
  def origin_kinds, do: @origin_kinds

  @doc """
  A track. The opening plan usually brings the id; one is minted otherwise.
  New rows reserve their branch across open and closed tracks, except a pull
  request's head branch, which belongs to the PR.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(track, attrs) do
    track
    |> cast(attrs, @fields)
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> validate_required(@required ++ [:visibility])
    |> check_constraint(:visibility, name: :tracks_visibility)
    |> validate_number(:rev, greater_than_or_equal_to: 1)
    |> validate_required([:sandbox_layout, :sandbox_generation])
    |> validate_number(:sandbox_generation, greater_than_or_equal_to: 0)
    |> unique_constraint(:sandbox_id, name: :tracks_dedicated_sandbox_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:project_id, :branch], name: :tracks_branch, error_key: :branch)
    |> unique_constraint(:id, name: :tracks_pkey)
    |> check_constraint(:origin_kind, name: :tracks_origin_kind)
    |> unique_constraint([:project_id, :slug],
      name: :tracks_slug,
      error_key: :slug,
      message: "is already an open track in this project"
    )
  end
end
