defmodule Ravix.Projects.Project do
  @moduledoc """
  Which project is which.

  Repository projects use GitHub’s full `owner/repository` name. Scratch
  projects receive a name at creation. Neither can be renamed independently.
  These identities belong to Ravix rather than Fountain. The three Fountain ids are the project. They are
  written once, at creation, and never updated: the sandbox is built from
  them, so a row that changed one would be a row pointing at a different
  machine. The one exception is `agent_id`, which moves on a rebuild and
  nothing else: retiring the agent is what changes the sandbox identity,
  while the environment and vault stay.

  `rev` is the settings revision. It is bumped whenever something Fountain
  injects at session start changes (a secret, an MCP server, a skill, the
  system prompt). Tracks already open carry the old number and are badged
  as running older settings, which is true and cannot be worked out any
  other way.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "projects" do
    belongs_to :user, Ravix.Accounts.User
    field :name, :string
    field :repo_full_name, :string
    field :repo_private, :boolean, default: false
    field :default_branch, :string
    field :installation_id, :integer
    field :shared_home_runtime, :string
    field :home_runtime, :string
    field :deletion_requested_at, :utc_datetime_usec
    field :runtime_agents_retiring, :boolean, default: false
    field :agent_id, :string
    field :environment_id, :string
    field :vault_id, :string
    field :runtime, :string
    field :model, :string
    # The owner's credential set the agent was last pointed at, or nil for an
    # agent on the deployment's default. See
    # `Ravix.Projects.Machine.adopt_credentials/2`.
    field :credential_set_id, :string
    field :secrets_generation, :integer, default: 0
    field :secrets_pending, :boolean, default: false
    field :shared_machine_retiring, :boolean, default: false
    field :rev, :integer, default: 1
    field :instructions, :string, default: ""
    field :created_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    # ADR 0009, expand only. A nil `workspace_id` is the legacy layout, and
    # nothing authorizes through any of these yet; see `Ravix.Workspaces`.
    # `created_by_user_id` is attribution copied from `user_id`, which stays
    # the legacy owner. The two legacy-duplicate fields are written only by
    # a reviewed migration, so `changeset/2` does not cast them.
    belongs_to :workspace, Ravix.Workspaces.Workspace
    field :created_by_user_id, :string
    field :normalized_repo_full_name, :string
    field :github_repo_id, :integer
    field :workspace_installation_id, :string
    field :legacy_duplicate_of, :string
    field :legacy_duplicate_at, :utc_datetime_usec

    has_many :tracks, Ravix.Tracks.Track
    has_many :members, Ravix.Projects.ProjectMember
    has_many :invites, Ravix.Projects.ProjectInvite
    has_one :link, Ravix.Projects.ProjectLink
    has_one :preview_default, Ravix.Previews.PreviewDefault
  end

  @fields ~w(id user_id name repo_full_name repo_private default_branch installation_id
             agent_id environment_id vault_id runtime model credential_set_id rev instructions
             created_at archived_at)a
  @required ~w(id user_id name agent_id environment_id runtime model rev created_at)a

  @doc "Provider identity of agent_id; runtime remains the default for new threads."
  def home_runtime(project), do: project.home_runtime || project.runtime

  @doc "Maintenance rollout follows the project owner, including member-triggered work."
  def maintenance?(project),
    do: Ravix.Config.dedicated_opens_enabled?(%Ravix.Accounts.User{id: project.user_id})

  @doc "A project with its three Fountain ids. Mints the id and `created_at` when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, @fields)
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    # Instructions may be cleared; the column is NOT NULL DEFAULT '' and
    # `cast/3` turns "" into nil, so put the empty string back.
    |> update_change(:instructions, &(&1 || ""))
    |> put_attribution()
    |> validate_required(@required)
    |> validate_number(:rev, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:id, name: :projects_pkey)
    |> unique_constraint(:repo_full_name,
      name: :projects_workspace_repo,
      message: "is already a project in this workspace"
    )
  end

  @doc """
  A project admitted to a workspace (ADR 0009 phase 4b): `changeset/2` plus
  the workspace, its connection and GitHub's repository id, which only
  admission writes.
  """
  @spec admission_changeset(t(), map()) :: Ecto.Changeset.t()
  def admission_changeset(project, attrs) do
    project
    |> changeset(attrs)
    |> cast(attrs, ~w(workspace_id workspace_installation_id github_repo_id)a)
    |> validate_required(~w(workspace_id workspace_installation_id repo_full_name)a)
  end

  # The dual write for the two ADR 0009 fields whose meaning is the same as
  # a legacy column's. An older release inserts nulls here instead, which
  # `Ravix.Workspaces.Backfill` fills and `Ravix.Workspaces` reads around.
  defp put_attribution(changeset) do
    changeset =
      if get_field(changeset, :created_by_user_id),
        do: changeset,
        else: put_change(changeset, :created_by_user_id, get_field(changeset, :user_id))

    put_change(
      changeset,
      :normalized_repo_full_name,
      normalize_repo(get_field(changeset, :repo_full_name))
    )
  end

  @doc """
  The comparison form of a repository name: trimmed of spaces, tabs and
  line breaks, and lowercased, as
  GitHub compares `owner/repository`. The display casing stays in
  `repo_full_name`. Nil for a scratch project, which has no repository.
  """
  @spec normalize_repo(String.t() | nil) :: String.t() | nil
  def normalize_repo(repo) when is_binary(repo) do
    # Exactly the characters the backfill's `btrim(?, E' \t\r\n')` strips,
    # so a row reads the same whichever of the two normalized it.
    case repo |> String.replace(~r/\A[ \t\r\n]+|[ \t\r\n]+\z/, "") |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_repo(_repo), do: nil

  @doc """
  Where the shared clone sits on the machine, or nil for a project with no
  repository.

  Here rather than at the three places that wanted it, which had written it
  twice as `project.repo_full_name && Ids.mount_path_for(project.repo_full_name)`
  and once as a private `repo_path/1` in `Ravix.Tracks` that also refused an
  empty string. Those two are not the same function: `Ids.mount_path_for/1`
  takes the last path segment, so the first spelling answers `"/workspace/"`
  for a project whose repository is `""` and the second answers nil. This is
  the second, because a project with a blank repository name has no clone.
  """
  @spec repo_path(t()) :: String.t() | nil
  def repo_path(%__MODULE__{repo_full_name: repo}) when is_binary(repo) and repo != "",
    do: Ravix.Ids.mount_path_for(repo)

  def repo_path(%__MODULE__{}), do: nil
end
