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

    # Which lifecycle action last wrote `sandbox_state`: open and rebuild both
    # write `:provisioning`. Nil on rows an earlier release wrote.
    field :sandbox_action, Ecto.Enum, values: [:open, :close, :rebuild]

    # When Fountain's stream (or a refused read) last said this dedicated
    # track's sandbox was suspended; cleared when a turn starts on it. A
    # signal Ravix already receives, kept so the rail need not ask anyone.
    field :sandbox_suspended_at, :utc_datetime_usec

    field :last_runtime, :string
    field :vault_id, :string
    field :conversation_id, :string
    field :slug, :string
    field :title, :string
    # RAV-48: `:auto` when Ravix titled it from the first prompt or the
    # runtime's session title, `:manual` when a person named it, nil for the
    # name it opened with. Written only through `Tracks.Store`.
    field :title_source, Ecto.Enum, values: [:auto, :manual]
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
    # The creator's GitHub avatar, joined by `Access.open_tracks/3` for the rail.
    field :creator_avatar_url, :string, virtual: true
    # When its newest prompt was accepted, joined by the same query: the
    # rail's last-activity age must not cost a query per row.
    field :last_prompt_at, :utc_datetime_usec, virtual: true
    field :visibility, Ecto.Enum, values: [:project, :private], default: :project
    # ADR 0009: who pays for this track's inference. `created_by` is the
    # creator. Written once, when a dedicated track is opened while
    # `RAVIX_CREATOR_BILLING` is on (`creator_billing_changeset/2`), and never
    # cast by `changeset/2`. A nil policy is a legacy owner-paid track.
    field :payer_user_id, :string
    field :billing_policy, Ecto.Enum, values: [:legacy_owner, :creator]
    # Harnesses paused because the payer's credential stopped serving, by
    # runtime; see `Ravix.Tracks.Billing`. Written only through `Tracks.Store`.
    field :billing_pauses, :map, default: %{}
    # When the creator was shown that collaborators' prompts spend their plan.
    field :billing_notice_at, :utc_datetime_usec

    has_many :threads, Ravix.Tracks.Thread
    has_many :prompts, Ravix.PromptQueue.Item
    has_many :members, Ravix.Tracks.TrackMember
    has_many :invites, Ravix.Tracks.TrackInvite
    has_many :reads, Ravix.Tracks.TrackRead
    has_one :link, Ravix.Tracks.TrackLink
    has_one :preview, Ravix.Previews.Preview
  end

  @fields ~w(visibility created_by last_runtime sandbox_layout sandbox_id sandbox_generation sandbox_state sandbox_action sandbox_suspended_at vault_id id project_id conversation_id slug title branch branch_reserved workdir origin_kind origin_base
             origin_number origin_title origin_url origin_plan_id origin_item_id rev setup_state setup_attempts setup_request_id setup_started_at setup_retry_at setup_error setup_error_code setup_lease setup_lease_until opened_at closed_at created_at created_by_login)a
  @required ~w(id project_id slug title branch workdir origin_kind rev created_at created_by_login)a

  @typedoc "Who pays for a track's inference, and under which policy."
  @type payer :: {:legacy_owner, String.t()} | {:creator, String.t() | nil}

  @doc """
  Who pays for every thread on `track` (ADR 0009, RAV-17 as clarified).

  A track no release has bound -- every track today, and every row an older
  release writes -- is `:legacy_owner`: its project's owner pays, under ADR
  0005, until it is backfilled or closed. A creator-billed track answers its
  bound payer, whoever starts or prompts the thread. That payer is nil if
  their account is gone, and nil means refuse, never fall back to the owner.
  """
  @spec payer(t(), Ravix.Projects.Project.t()) :: payer()
  def payer(%__MODULE__{project_id: id} = track, %Ravix.Projects.Project{id: id} = project) do
    case track.billing_policy do
      :creator -> {:creator, track.payer_user_id}
      _legacy -> {:legacy_owner, project.user_id}
    end
  end

  @doc """
  Bind a new track's inference to its creator (ADR 0009 phase 6).

  Only the opening of a dedicated track calls this, and only while
  `Ravix.Config.creator_billing?/0` is on. The payer is `created_by`, never
  somebody the request names.
  """
  @spec creator_billing_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def creator_billing_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> put_change(:billing_policy, :creator)
    |> put_change(:payer_user_id, get_field(changeset, :created_by))
    |> validate_required([:payer_user_id])
    |> check_constraint(:billing_policy, name: :tracks_billing_policy)
  end

  @doc "Whether this track's inference is its creator's, whoever prompts it."
  @spec creator_billed?(t()) :: boolean()
  def creator_billed?(%__MODULE__{billing_policy: :creator}), do: true
  def creator_billed?(%__MODULE__{}), do: false

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
