defmodule Ravix.Tracks.Git do
  @moduledoc """
  The Checks tab's Git status, and the two writes it offers: commit and push,
  and push.

  Pure: the shell commands `Ravix.Tracks` runs on the track's machine through
  `Ravix.Terminal.exec/3`, and what their output means. Nothing here reaches a
  provider, so each answer can be tested against the text Git prints.

  Every command runs in a subshell and names the step that failed by its exit
  status, because "git exited 1" is not something a person can act on and
  "the push was rejected" is. A step's own output is kept, tail only, so a
  failing commit hook says what it failed on.
  """

  alias Ravix.Sprites

  defmodule Status do
    @moduledoc """
    What the worktree holds that the remote does not.

    `uncommitted` is the entries `git status --porcelain` lists, untracked
    files included. `unpushed` is `git rev-list --count @{u}..HEAD` when the
    branch has an upstream; without one (`upstream?: false`) it is the commits
    no remote branch has, which is what a branch that was never pushed has.
    `branch` is nil on a detached HEAD.
    """

    @enforce_keys [:uncommitted, :unpushed, :upstream?, :branch]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            uncommitted: non_neg_integer(),
            unpushed: non_neg_integer(),
            upstream?: boolean(),
            branch: String.t() | nil
          }
  end

  @type failure ::
          {:conflict, String.t(), String.t()} | {:unavailable, String.t(), String.t()}

  @marker "__ravix_git__"

  # The step a failing command stopped at, as its subshell's exit status.
  @add_failed 10
  @commit_failed 11
  @push_failed 12
  @nothing_staged 13
  @detached 14
  @not_a_repo 15

  # A commit message is the person's words and goes to Git as one argument;
  # the cap keeps the quoted command inside `Ravix.Terminal.Request`'s.
  @message_max 2_000

  @doc "The one command that reads `t:Status.t/0`: porcelain, branch and ahead count."
  @spec status_command() :: String.t()
  def status_command do
    """
    (
      git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit #{@not_a_repo}
      git status --porcelain || exit #{@not_a_repo}
      echo #{@marker}
      git symbolic-ref -q --short HEAD || echo
      if git rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1; then
        echo "upstream $(git rev-list --count '@{upstream}..HEAD')"
      else
        echo "none $(git rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
      fi
    )
    """
  end

  @doc "Read `status_command/0`'s output."
  @spec parse_status(map()) :: {:ok, Status.t()} | {:error, failure()}
  def parse_status(%{code: 0, stdout: stdout}) do
    with [porcelain, rest] <- String.split(stdout, @marker <> "\n", parts: 2),
         [branch, ahead | _] <- String.split(rest, "\n"),
         [kind, count] <- String.split(String.trim(ahead), " ", parts: 2),
         {unpushed, ""} <- Integer.parse(count) do
      {:ok,
       %Status{
         uncommitted: porcelain |> String.split("\n", trim: true) |> length(),
         unpushed: unpushed,
         upstream?: kind == "upstream",
         branch: if(String.trim(branch) == "", do: nil, else: String.trim(branch))
       }}
    else
      _ -> {:error, unreadable()}
    end
  end

  def parse_status(result), do: {:error, failure(result, :status)}

  @doc """
  Stage everything, commit it with `message` and push the branch, setting its
  upstream. Stops at the first step that fails and says which.
  """
  @spec commit_and_push_command(String.t()) :: String.t()
  def commit_and_push_command(message) do
    """
    (
      #{on_branch()}
      git add -A || exit #{@add_failed}
      git diff --cached --quiet && exit #{@nothing_staged}
      git commit -q -m #{Sprites.shq(message)} || exit #{@commit_failed}
      git push -u origin HEAD || exit #{@push_failed}
    ) 2>&1
    """
  end

  @doc "Push the branch as it stands, setting its upstream."
  @spec push_command() :: String.t()
  def push_command do
    """
    (
      #{on_branch()}
      git push -u origin HEAD || exit #{@push_failed}
    ) 2>&1
    """
  end

  defp on_branch, do: "git symbolic-ref -q HEAD >/dev/null || exit #{@detached}"

  @doc "The longest commit message accepted."
  @spec message_max() :: pos_integer()
  def message_max, do: @message_max

  @doc """
  What a write's result means: `:ok`, or the refusal to show. `step` is
  `:commit` for commit and push, whose push failing leaves a commit behind,
  or `:push`.
  """
  @spec written(map(), :commit | :push) :: :ok | {:error, failure()}
  def written(%{code: 0}, _step), do: :ok
  def written(result, step), do: {:error, failure(result, step)}

  defp failure(%{timed_out: true}, _step),
    do:
      {:unavailable, "git_timeout",
       "Git did not finish in time. It may still be running on the machine; refresh to see where it got to."}

  defp failure(%{code: @not_a_repo}, _step),
    do: {:conflict, "not_a_repository", "This track's working directory is not a Git repository."}

  defp failure(%{code: @detached}, _step),
    do:
      {:conflict, "detached_head",
       "The worktree is not on a branch, so there is no branch to push. Check out the track's branch first."}

  defp failure(%{code: @nothing_staged}, _step),
    do: {:conflict, "nothing_to_commit", "There is nothing to commit."}

  defp failure(%{code: @add_failed} = result, _step),
    do: {:conflict, "stage_failed", "Git could not stage the changes." <> tail(result)}

  defp failure(%{code: @commit_failed} = result, _step),
    do:
      {:conflict, "commit_failed",
       "The commit was refused, so nothing was pushed. A commit hook may have failed." <>
         tail(result)}

  defp failure(%{code: @push_failed} = result, step) do
    {code, sentence} = push_failure(output(result))
    prefix = if step == :commit, do: "Committed, but the push failed. ", else: ""
    {:conflict, code, prefix <> sentence <> tail(result)}
  end

  defp failure(result, _step),
    do: {:conflict, "git_failed", "Git failed on the machine." <> tail(result)}

  # The order matters: a hook on the remote declining the push also prints
  # "[remote rejected]", and that is a refusal to read rather than a branch
  # to rebase.
  defp push_failure(output) do
    cond do
      output =~
          ~r/no configured push destination|does not appear to be a git repository|no such remote/i ->
        {"no_upstream", "This branch has no remote to push to."}

      output =~
          ~r/authentication failed|could not read username|permission to .* denied|error: 403|returned error: 403/i ->
        {"push_unauthorized", "The machine's Git credential was refused by the remote."}

      output =~ ~r/\[remote rejected\]|pre-receive hook declined|protected branch/i ->
        {"push_refused", "The remote refused the push."}

      output =~ ~r/\[rejected\]|non-fast-forward|fetch first|updates were rejected/i ->
        {"push_rejected",
         "The push was rejected: the remote branch has commits this one does not. Ask the agent to pull or rebase, then push again."}

      # A local pre-push hook that exits non-zero leaves only its own output
      # and "failed to push some refs", which is the tail below.
      true ->
        {"push_failed", "The push failed."}
    end
  end

  defp unreadable,
    do: {:unavailable, "git_status_unreadable", "Could not read the Git status on the machine."}

  defp output(result), do: "#{Map.get(result, :stdout)}\n#{Map.get(result, :stderr)}"

  # What Git said last, which is where it says why. A remote's URL can carry
  # the credential the machine pushes with, so userinfo and anything shaped
  # like a GitHub token go before it is shown.
  @tail_lines 8
  @tail_chars 800

  defp tail(result) do
    text =
      result
      |> output()
      |> String.replace(~r{(\w+://)[^/@\s]+@}, "\\1")
      |> String.replace(~r/\b(gh[pousr]|github_pat)_[A-Za-z0-9_]+/, "[redacted]")
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(-@tail_lines)
      |> Enum.join("\n")

    cond do
      text == "" -> ""
      String.length(text) > @tail_chars -> "\n\n…" <> String.slice(text, -@tail_chars..-1//1)
      true -> "\n\n" <> text
    end
  end
end
