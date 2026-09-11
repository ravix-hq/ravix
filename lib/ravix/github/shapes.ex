defmodule Ravix.GitHub.Shapes do
  @moduledoc """
  The shapes GitHub actually sends, and the ones the rest of Ravix reads.

  GitHub's JSON arrives as string-keyed maps, which is the only place in
  Ravix where a field is addressed by a string nobody checks. These
  functions are the boundary: past them, a repository is a `RepoRef` and a
  pull request is a `PullRef`, with atom keys and snake_case names.

  Structs, not the bare maps they were. A map type is a comment -- it
  describes what a function means to build, and nothing verifies it, so
  `%{full_nam: r["full_name"]}` compiles and ships and the panel reading
  `.full_name` fails on a value that satisfied `repo_ref()` as far as
  anything could tell. `@enforce_keys` moves that to where the value is
  built, and a misspelled field becomes a compile error.

  What it cannot check is the string on the other side: `r["full_name"]`
  quietly answers `nil` if GitHub ever renames it. That is the nature of the
  boundary and the reason for keeping it thin -- these six functions are the
  whole of it.
  """

  defmodule RepoRef do
    @moduledoc "A repository, as the installation that can see it."

    @enforce_keys [
      :full_name,
      :owner,
      :name,
      :private,
      :default_branch,
      :description,
      :pushed_at,
      :language,
      :installation_id
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            full_name: String.t(),
            owner: String.t() | nil,
            name: String.t(),
            private: boolean(),
            default_branch: String.t(),
            description: String.t() | nil,
            pushed_at: String.t() | nil,
            language: String.t() | nil,
            installation_id: integer()
          }
  end

  defmodule BranchRef do
    @moduledoc "A branch, flagged when it is the repository's default."

    @enforce_keys [:name, :sha, :is_default]
    defstruct @enforce_keys

    @type t :: %__MODULE__{name: String.t(), sha: String.t() | nil, is_default: boolean()}
  end

  defmodule PullRef do
    @moduledoc "A pull request. `state` is where it got to: a merged one says so."

    @enforce_keys [
      :number,
      :title,
      :author,
      :head_ref,
      :base_ref,
      :draft,
      :updated_at,
      :state,
      :url
    ]
    defstruct @enforce_keys

    @type state :: :open | :closed | :merged

    @type t :: %__MODULE__{
            number: integer(),
            title: String.t(),
            author: String.t() | nil,
            head_ref: String.t() | nil,
            base_ref: String.t() | nil,
            draft: boolean(),
            updated_at: String.t(),
            state: state(),
            url: String.t() | nil
          }
  end

  defmodule IssueRef do
    @moduledoc "An issue, with its labels reduced to names."

    @enforce_keys [:number, :title, :author, :labels, :updated_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            number: integer(),
            title: String.t(),
            author: String.t() | nil,
            labels: [String.t()],
            updated_at: String.t()
          }
  end

  defmodule CheckRun do
    @moduledoc """
    One check run, as the Checks tab shows it. `status` is how far GitHub
    got and `conclusion` is how it came out, which is `nil` until it has.
    """

    @enforce_keys [:name, :status, :conclusion, :url, :started_at, :completed_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            status: String.t(),
            conclusion: String.t() | nil,
            url: String.t() | nil,
            started_at: String.t() | nil,
            completed_at: String.t() | nil
          }
  end

  defmodule Installation do
    @moduledoc "An installation as the repository picker lists it."

    @enforce_keys [:id, :account, :avatar_url]
    defstruct @enforce_keys

    @type t :: %__MODULE__{id: integer(), account: String.t(), avatar_url: String.t() | nil}
  end

  defmodule Account do
    @moduledoc "A GitHub account: the four fields sign-in and invitations use."

    @enforce_keys [:id, :login, :name, :avatar_url]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: integer(),
            login: String.t(),
            name: String.t() | nil,
            avatar_url: String.t() | nil
          }
  end

  @doc "A repository, as the installation that can see it."
  @spec repo_ref(map(), integer()) :: RepoRef.t()
  def repo_ref(%{} = r, installation_id) do
    %RepoRef{
      full_name: r["full_name"],
      owner: get_in(r, ["owner", "login"]),
      name: r["name"],
      private: r["private"] == true,
      default_branch: r["default_branch"],
      description: r["description"],
      pushed_at: r["pushed_at"],
      language: r["language"],
      installation_id: installation_id
    }
  end

  @doc "A pull request. `state` is where it got to: a merged one says so."
  @spec pull_ref(map()) :: PullRef.t()
  def pull_ref(%{} = p) do
    %PullRef{
      number: p["number"],
      title: p["title"],
      author: get_in(p, ["user", "login"]),
      head_ref: get_in(p, ["head", "ref"]),
      base_ref: get_in(p, ["base", "ref"]),
      draft: p["draft"] == true,
      updated_at: p["updated_at"],
      state: pull_state(p),
      url: p["html_url"]
    }
  end

  @doc "Where a pull request got to: merged, closed or open."
  @spec pull_state(map()) :: PullRef.state()
  def pull_state(%{} = p) do
    cond do
      is_binary(p["merged_at"]) -> :merged
      p["state"] == "closed" -> :closed
      true -> :open
    end
  end

  @doc "An issue. Labels arrive as strings or objects; both become names."
  @spec issue_ref(map()) :: IssueRef.t()
  def issue_ref(%{} = i) do
    %IssueRef{
      number: i["number"],
      title: i["title"],
      author: get_in(i, ["user", "login"]),
      # A label GitHub sends in some other shape is a label we cannot name, not
      # a reason to raise `FunctionClauseError` out of `GitHub.issues/3`.
      labels:
        i["labels"]
        |> List.wrap()
        |> Enum.flat_map(fn
          name when is_binary(name) -> [name]
          %{"name" => name} when is_binary(name) -> [name]
          _unnamed -> []
        end),
      updated_at: i["updated_at"]
    }
  end

  @doc "A branch, flagged when it is the repository's default."
  @spec branch_ref(map(), String.t()) :: BranchRef.t()
  def branch_ref(%{} = b, default_branch) do
    %BranchRef{
      name: b["name"],
      sha: get_in(b, ["commit", "sha"]),
      is_default: b["name"] == default_branch
    }
  end

  @doc "One check run, as the Checks tab shows it."
  @spec check_run(map()) :: CheckRun.t()
  def check_run(%{} = r) do
    %CheckRun{
      name: r["name"],
      status: r["status"],
      conclusion: r["conclusion"],
      url: r["html_url"],
      started_at: r["started_at"],
      completed_at: r["completed_at"]
    }
  end

  @doc "An installation as the repository picker lists it."
  @spec installation(map()) :: Installation.t()
  def installation(%{} = i) do
    %Installation{
      id: i["id"],
      account: get_in(i, ["account", "login"]) || "(unknown)",
      avatar_url: get_in(i, ["account", "avatar_url"])
    }
  end

  @doc "A GitHub account: the four fields sign-in and invitations use."
  @spec account(map()) :: Account.t()
  def account(%{} = u) do
    %Account{id: u["id"], login: u["login"], name: u["name"], avatar_url: u["avatar_url"]}
  end
end
