defmodule Ravix.GitHub.Shapes do
  @moduledoc """
  The shapes GitHub actually sends, and the ones the rest of Ravix reads.

  GitHub's JSON arrives as string-keyed maps. These turn them into the
  `RepoRef`, `PullRef`, `IssueRef`, `BranchRef` and `CheckRun` maps from
  `shared/api.ts` (atom keys, snake_case), keeping only what the pages show.
  """

  @type repo_ref :: %{
          full_name: String.t(),
          owner: String.t(),
          name: String.t(),
          private: boolean(),
          default_branch: String.t(),
          description: String.t() | nil,
          pushed_at: String.t() | nil,
          language: String.t() | nil,
          installation_id: integer()
        }

  @type branch_ref :: %{name: String.t(), sha: String.t(), is_default: boolean()}

  @type pull_ref :: %{
          number: integer(),
          title: String.t(),
          author: String.t() | nil,
          head_ref: String.t(),
          base_ref: String.t(),
          draft: boolean(),
          updated_at: String.t(),
          state: :open | :closed | :merged,
          url: String.t() | nil
        }

  @type issue_ref :: %{
          number: integer(),
          title: String.t(),
          author: String.t() | nil,
          labels: [String.t()],
          updated_at: String.t()
        }

  @type check_run :: %{
          name: String.t(),
          status: String.t(),
          conclusion: String.t() | nil,
          url: String.t() | nil,
          started_at: String.t() | nil,
          completed_at: String.t() | nil
        }

  @type installation :: %{id: integer(), account: String.t(), avatar_url: String.t() | nil}

  @type account :: %{
          id: integer(),
          login: String.t(),
          name: String.t() | nil,
          avatar_url: String.t() | nil
        }

  @doc "A repository, as the installation that can see it."
  @spec repo_ref(map(), integer()) :: repo_ref()
  def repo_ref(%{} = r, installation_id) do
    %{
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
  @spec pull_ref(map()) :: pull_ref()
  def pull_ref(%{} = p) do
    %{
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
  @spec pull_state(map()) :: :open | :closed | :merged
  def pull_state(%{} = p) do
    cond do
      is_binary(p["merged_at"]) -> :merged
      p["state"] == "closed" -> :closed
      true -> :open
    end
  end

  @doc "An issue. Labels arrive as strings or objects; both become names."
  @spec issue_ref(map()) :: issue_ref()
  def issue_ref(%{} = i) do
    %{
      number: i["number"],
      title: i["title"],
      author: get_in(i, ["user", "login"]),
      labels:
        Enum.map(i["labels"] || [], fn
          name when is_binary(name) -> name
          %{"name" => name} -> name
        end),
      updated_at: i["updated_at"]
    }
  end

  @doc "A branch, flagged when it is the repository's default."
  @spec branch_ref(map(), String.t()) :: branch_ref()
  def branch_ref(%{} = b, default_branch) do
    %{name: b["name"], sha: get_in(b, ["commit", "sha"]), is_default: b["name"] == default_branch}
  end

  @doc "One check run, as the Checks tab shows it."
  @spec check_run(map()) :: check_run()
  def check_run(%{} = r) do
    %{
      name: r["name"],
      status: r["status"],
      conclusion: r["conclusion"],
      url: r["html_url"],
      started_at: r["started_at"],
      completed_at: r["completed_at"]
    }
  end

  @doc "An installation as the repository picker lists it."
  @spec installation(map()) :: installation()
  def installation(%{} = i) do
    %{
      id: i["id"],
      account: get_in(i, ["account", "login"]) || "(unknown)",
      avatar_url: get_in(i, ["account", "avatar_url"])
    }
  end

  @doc "A GitHub account: the four fields sign-in and invitations use."
  @spec account(map()) :: account()
  def account(%{} = u) do
    %{id: u["id"], login: u["login"], name: u["name"], avatar_url: u["avatar_url"]}
  end
end
