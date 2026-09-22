defmodule Ravix.Accounts.User do
  @moduledoc """
  Who signed in.

  Fountain owns the truth about machines and conversations; this database
  owns the truth about people, and this is the first of those tables. A user
  is identified by GitHub's numeric id, never the login: logins are
  renameable, and a login freed by a deleted account can be taken by somebody
  else. `login`, `name` and `avatar_url` are refreshed on every sign-in and
  are allowed to be stale in between.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "users" do
    field :github_id, :string
    field :login, :string
    field :name, :string
    field :avatar_url, :string
    # The user's OAuth token, encrypted. Refreshed on each sign-in.
    # The GitHub OAuth token, encrypted. Redacted because a `%User{}` is the
    # `current_user` assign on every page, so any crash report or `inspect`
    # of a socket would otherwise write it to the log.
    field :token_enc, :string, redact: true
    # Which agent this person runs and the Fountain credential set that pays
    # for it. The set holds their subscription token or API key; only its id
    # is ever here. See `Ravix.Accounts.Inference`.
    field :agent, Ecto.Enum, values: [:claude, :codex]
    field :credential_set_id, :string
    field :credential_kind, Ecto.Enum, values: [:subscription, :api_key]
    # When the first-run walkthrough was finished or dismissed.
    field :onboarded_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    has_many :sessions, Ravix.Accounts.Session
    has_many :projects, Ravix.Projects.Project
  end

  @fields ~w(id github_id login name avatar_url token_enc created_at last_seen_at)a

  @typedoc "The two agents a person can bring a subscription for."
  @type agent :: :claude | :codex

  @typedoc "What pays for the agent: a subscription's token, or a metered API key."
  @type credential_kind :: :subscription | :api_key

  @doc "The agents on offer, in the order the walkthrough shows them."
  @spec agents() :: [agent()]
  def agents, do: Ecto.Enum.values(__MODULE__, :agent)

  @doc "A user from a GitHub profile. Mints the id and both timestamps when absent."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, @fields)
    |> Ravix.Schema.put_new_id()
    |> Ravix.Schema.stamp(:created_at)
    |> Ravix.Schema.stamp(:last_seen_at)
    |> validate_required([:id, :github_id, :login, :created_at, :last_seen_at])
    |> unique_constraint(:github_id)
  end

  @doc """
  What a person set up about themselves, as opposed to what GitHub says about
  them. Kept apart from `changeset/2` so a sign-in, which replaces every
  GitHub field, cannot be handed one of these by mistake.
  """
  @spec setup_changeset(t(), map()) :: Ecto.Changeset.t()
  def setup_changeset(user, attrs) do
    user
    |> cast(attrs, [:agent, :credential_set_id, :credential_kind, :onboarded_at])
    |> check_constraint(:agent, name: :users_agent)
    |> check_constraint(:credential_kind, name: :users_credential_kind)
  end
end
