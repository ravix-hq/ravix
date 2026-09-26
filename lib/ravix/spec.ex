defmodule Ravix.Spec do
  @moduledoc """
  The prompt contract: what ravix asks the machine to do, and how the
  machine reports back. Per-app on purpose: this and `Ravix.Ids` are the two
  modules the demo suite never shares, because they *are* the product.

  Ravix's whole shape follows from one fact and one wish.

  The fact: a project is **one machine**. Fountain builds a sandbox from an
  identity, `(user, agent, environment, vault)` by id, so a project that
  keeps one agent, one environment and one vault gets one persistent box that
  every conversation on it attaches to. Change any of those ids and the disk
  is gone.

  The wish: several pieces of work at once, on that one machine, without them
  treading on each other. Which is exactly what `git worktree` is for. So a
  track is a worktree, and the agent must never be tempted to `cd` somewhere
  else and start editing the shared clone.

  "Must never be tempted" is doing real work in that sentence. There is no
  chroot here and no per-track permission: the isolation is a rule the agent
  follows. So the rule is stated in three places that reinforce each other:
  the system prompt (every turn), the track's opening turn (where the worktree
  is actually made), and the header of every prompt ravix sends itself.
  Saying it once and hoping is how two tracks end up committing to the same
  branch.

  This module is where that text lives. It had a TypeScript twin while the
  old server was still serving; it does not any more, because a prompt
  contract kept in two languages is a contract that can disagree with itself.

  It takes the domain structs the prompts are *about* --- a
  `Ravix.Projects.Project` and a `Ravix.Tracks.Origin` --- rather than maps
  of the fields it reads. The maps were the TypeScript twin's argument
  objects surviving the port: four functions took one, each built inline at
  one call site, and the project's clone path was derived by the caller,
  three times, two different ways. `Project.repo_path/1` is that derivation,
  once.
  """

  alias Ravix.Ids
  alias Ravix.Projects.Project
  alias Ravix.Spec.Starter
  alias Ravix.Tracks.Origin

  @typedoc """
  How a track was started, in the words the header will use.

  `Ravix.Tracks.Origin`, not a shape of its own. This was a map type that
  required two keys, made two optional and accepted `kind` as either the atom
  or the string --- so `open_track_prompt/4` narrowed the kind a second time
  through a private `kind_of/1`, after `Ravix.Tracks.read_origin/2` had
  already done it, and `issue_lines/1` had to reach for the title through
  `origin[:title]` because the type said it might not be there. Taking the
  struct, both of those go: the kind is an atom because there is no way to
  build an `Origin` holding anything else, and every field exists.
  """
  @type origin :: Origin.t()

  @doc "What the machine writes to say what it did. Read with `GET /api/sandboxes/:id/file`."
  @spec receipt_path() :: String.t()
  def receipt_path, do: "#{Ids.state_dir()}/tracks.json"

  @doc """
  The system prompt for a project's agent.

  It is the only mechanism ravix has for keeping tracks apart, so it spends
  its length on that and on nothing else. Everything the app could instead
  put in a per-turn preamble is here, because a system prompt is on every
  turn including the ones a person types in a hurry.

  Takes the project. The three things it reads --- the name, the shared
  clone's path and the trunk --- are all the project's, and it was taking a
  three-key map built at its one call site, which is a TypeScript argument
  object rather than an Elixir argument.
  """
  @spec system_prompt(Project.t()) :: String.t()
  def system_prompt(%Project{name: name, default_branch: default_branch} = project) do
    repo_path = Project.repo_path(project)
    work_root = Ids.work_root()

    [
      ~s(You are the coding agent on the Ravix machine for the project "#{name}".),
      "",
      "## The one rule",
      "",
      "Every piece of work happens in its own git worktree under #{work_root}. Each",
      "conversation you are in — Ravix calls it a *track* — owns exactly one of those",
      "directories, and its first turn tells you which. That directory is your working",
      "directory for the whole of that conversation.",
      "",
      "Never edit, stage, commit or check out anything outside your own track's directory.",
      "In particular:",
      ""
    ]
    |> append_if(repo_path, [
      "  - #{repo_path} is the shared clone. It is the source the worktrees come from.",
      "    Read it if you must; do not modify it, do not commit in it, and never change",
      "    the branch it has checked out. Another track is using it."
    ])
    |> Kernel.++([
      "  - Other directories under #{work_root} belong to other tracks, running right now.",
      "    Do not read from them to \"check something\" and never write to them.",
      "",
      "If a request would take you outside your track's directory, say so and ask, rather",
      "than doing it. A track that quietly edits another track's branch is the one failure",
      "this machine cannot recover from.",
      "",
      "## What is true of this machine",
      "",
      "It persists. The disk is the same one next time, for every track. It runs one turn",
      "at a time across all tracks, because it is one computer — if you are asked why a",
      "track is waiting, that is why.",
      ""
    ])
    |> append_if(repo_path, [
      "Git is configured for pushing: the remote carries a credential Ravix supplies",
      "and re-mints before each turn, so `git push -u origin <your branch>` works. Push",
      "when the person asks and not before. Open pull requests with `gh` if it is present,",
      "otherwise say what you would open and let Ravix do it.",
      ""
    ])
    |> append_if(repo_path && default_branch, [
      "The trunk is `#{default_branch}`. Branch from it and merge back to it.",
      ""
    ])
    |> Kernel.++([
      "## Live previews",
      "",
      "Ravix can provide a track-scoped preview helper in the turn's instructions.",
      "When asked to configure or run a live preview, use that helper to save the app",
      "directory, startup command and readiness path, then start it and inspect status",
      "and logs. The command must use $PORT and fail on a port collision. Keep the",
      "preview on this track's working copy. Tell the user to use Open preview after",
      "readiness passes. Do not ask for their browser session or provider credentials.",
      "",
      "## How to answer",
      "",
      "Be concise. This is rendered in a terminal-shaped panel, not a document. Prefer",
      "doing the thing to describing the thing. No summaries of what you are about to do,",
      "no recap afterwards unless it is genuinely non-obvious.",
      "",
      ~s(Turns whose first line starts with "[ravix]" come from the app itself rather),
      "than a person. Follow those exactly, including any strings they ask you to write",
      "back verbatim."
    ])
    |> Enum.join("\n")
  end

  @doc """
  A track's opening turn: cut the worktree, then say where you are.

  This is a real turn rather than something the server does over exec, and
  that is deliberate on two counts. It works on a Fountain with no Sprites
  token, which is the configuration ravix must always run in. And the first
  thing a person sees in a new track is the machine actually making their
  branch, in the scrollback, which is the product.

  The fallbacks matter more than they look. A repository with no commits has
  no ref to branch from; a directory left behind by a track that was closed
  badly will refuse the add. A track that dies at `git worktree add` is a
  track a person cannot use at all, so it degrades to a plain directory. That
  is a fault rather than an outcome, though: it leaves the track with no
  branch, so the reply leads with `error:` and git's own message, where a
  person will see it.

  The fetches ask for escalation up front. Fountain makes the shared clone
  writable inside codex's sandbox, but the sandbox still has no network, and
  codex will not ask for it on its own; a fetch tried inside the sandbox
  first just fails. Escalating keeps codex's approvals on, which is the point
  of not running the whole agent with full access.

  The two shapes are a project with a clone and one without, which is the
  `Project.repo_path/1` question rather than anything a caller has to work
  out and pass in.
  """
  @spec open_track_prompt(Project.t(), origin(), String.t(), String.t()) :: String.t()
  def open_track_prompt(%Project{} = project, %Origin{} = origin, slug, branch) do
    case Project.repo_path(project) do
      nil -> plain_directory(slug)
      repo_path -> worktree(repo_path, origin, slug, branch)
    end
  end

  defp plain_directory(slug) do
    dir = Ids.workdir_for(slug)

    Enum.join(
      [
        "[ravix] Open this track. Make its working directory, then stop.",
        "",
        "This project has no repository yet, so the track is a plain directory:",
        "",
        "  mkdir -p #{dir} && cd #{dir}",
        "",
        "Reply with exactly one line: the working directory. Nothing else."
      ],
      "\n"
    )
  end

  defp worktree(repo_path, origin, slug, branch) do
    dir = Ids.workdir_for(slug)

    Enum.join(
      [
        "[ravix] Open this track. Make its working directory, then stop.",
        "",
        "The shared clone is #{repo_path}. Give this track its own worktree so it can",
        "hold a branch without disturbing the tracks already running:",
        "",
        "  cd #{repo_path}",
        "  git fetch origin --prune",
        "",
        "The sandbox has no network and will not ask for it. Run every `git fetch` in",
        "this turn with escalated permissions, outside the sandbox, on the first attempt."
      ] ++
        cut_lines(origin, dir, branch) ++
        [
          "",
          "Then `cd #{dir}` — that is your working directory for every turn in this track."
        ] ++
        issue_lines(origin) ++
        [
          "",
          "Reply with exactly one line: the working directory and the branch it is on. If",
          "the worktree could not be made, that is a fault, not a normal outcome: reply",
          "`error:` followed by the plain directory and git's error message. No preamble,",
          "no summary, no next steps, no offer to begin."
        ],
      "\n"
    )
  end

  # Git allows shell metacharacters in refs. Keep readable ordinary names,
  # but quote everything else before suggesting an executable command.
  defp shell_ref(ref) do
    if Regex.match?(~r/\A[a-zA-Z0-9_\/.+-]+\z/, ref), do: ref, else: Ravix.Sprites.shq(ref)
  end

  defp cut_lines(%Origin{kind: :pr, number: number} = origin, dir, branch)
       when is_integer(number) do
    base = if origin.base, do: shell_ref("origin/#{origin.base}"), else: "HEAD"

    [
      "",
      "This track continues pull request ##{number}. Check out its head rather than",
      "cutting a new branch — the work belongs on the branch the PR is already for:",
      "",
      "  git fetch origin #{shell_ref("pull/#{number}/head:#{branch}")} 2>/dev/null \\",
      "    && git worktree add #{dir} #{shell_ref(branch)} \\",
      "    || git worktree add #{dir} -b #{shell_ref(branch)} #{base}"
    ]
  end

  defp cut_lines(%Origin{kind: :branch, base: base}, dir, branch)
       when is_binary(base) and base != "" do
    [
      "",
      "Cut a new branch `#{branch}` from `origin/#{base}`:",
      "",
      "  git worktree add #{dir} -b #{shell_ref(branch)} #{shell_ref("origin/#{base}")} \\",
      "    || mkdir -p #{dir}"
    ]
  end

  defp cut_lines(%Origin{base: base}, dir, branch) do
    from = if base, do: " from `origin/#{base}`", else: ""
    at = if base, do: " #{shell_ref("origin/#{base}")}", else: ""

    [
      "",
      "Cut a new branch `#{branch}`#{from}:",
      "",
      "  git worktree add #{dir} -b #{shell_ref(branch)}#{at} 2>/dev/null \\",
      "    || git worktree add #{dir} -b #{shell_ref(branch)} \\",
      "    || mkdir -p #{dir}"
    ]
  end

  defp issue_lines(%Origin{kind: :issue, number: number} = origin) when is_integer(number) do
    titled = if origin.title, do: ~s(, "#{origin.title}"), else: ""

    [
      "",
      "This track exists to work on issue ##{number}#{titled}. Do not start",
      "on it yet; the person will say what they want first."
    ]
  end

  defp issue_lines(_origin), do: []

  @doc """
  The turn that closes a track: take the worktree away.

  `git worktree remove` rather than `rm -rf`, because the shared clone keeps
  an administrative record of every worktree it cut and a directory deleted
  from underneath it leaves that record behind, after which the *next* track
  with the same name is refused.

  The branch is left alone unless somebody ticks the box. That default is the
  important half: closing a track is a tab shut, and a gesture that quietly
  deleted a branch (pushed, reviewed, possibly someone else's open pull
  request) would be the most expensive undo in the app. When the box *is*
  ticked it goes properly, locally and on the remote, because a branch deleted
  in one place and left in the other is the worst of both.

  The two decisions are options because that is what they are --- both
  default to the safe answer and the caller ticks a box --- and they arrive
  as a keyword list, which is what `Ravix.Tracks.close/3` already has in
  hand. They were a map with one required key and one `optional(:delete_branch)`
  read back out through `Map.get/2`, which is a keyword list with extra steps.
  """
  @spec close_track_prompt(Project.t(), String.t(), keyword()) :: String.t()
  def close_track_prompt(%Project{} = project, slug, opts \\ []) do
    case Project.repo_path(project) do
      nil -> remove_directory(slug)
      repo_path -> remove_worktree(repo_path, slug, opts)
    end
  end

  defp remove_directory(slug) do
    dir = Ids.workdir_for(slug)

    Enum.join(
      [
        "[ravix] Close this track. Remove its working directory, then stop.",
        "",
        "  rm -rf #{dir}",
        "",
        "Reply with one line saying whether it went."
      ],
      "\n"
    )
  end

  defp remove_worktree(repo_path, slug, opts) do
    dir = Ids.workdir_for(slug)
    force = Keyword.get(opts, :force, false)
    delete_branch = Keyword.get(opts, :delete_branch)

    branch_line =
      if delete_branch do
        "Then delete the branch `#{delete_branch}` — this close was asked for with the branch, so:\n\n" <>
          "  git branch -D #{shell_ref(delete_branch)}\n" <>
          "  git push origin --delete #{shell_ref(delete_branch)} 2>/dev/null || true\n\n" <>
          "The push may fail because the branch was never pushed; that is fine and not worth reporting as an error."
      else
        "Leave the branch alone — it may be pushed, and it is not this turn's business."
      end

    force_line =
      if force,
        do:
          "This is a forced close: uncommitted changes in that worktree are being discarded on purpose.",
        else: "If the worktree has uncommitted changes, stop and say so instead of forcing it."

    Enum.join(
      [
        "[ravix] Close this track. Remove its worktree, then stop.",
        "",
        "  cd #{repo_path}",
        "  git worktree remove #{if force, do: "--force ", else: ""}#{dir}",
        "  git worktree prune",
        "",
        branch_line,
        force_line,
        "",
        "Reply with one line saying what happened."
      ],
      "\n"
    )
  end

  @doc """
  Ask the machine what its tracks actually look like.

  Ravix's database says which tracks it *believes* exist. This asks the box,
  and the two disagreeing is ordinary rather than exceptional: a rebuild, a
  worktree a person removed by hand in the terminal, a branch pushed and
  deleted. The panel shows what the machine said, not what the row claimed.
  """
  @spec survey_prompt() :: String.t()
  def survey_prompt do
    Enum.join(
      [
        "[ravix] Report what is on this machine. Change nothing.",
        "",
        "  cd #{Ids.workspace_root()} 2>/dev/null && ls -1",
        "  git --git-dir=*/.git worktree list 2>/dev/null || true",
        "",
        "Then write #{receipt_path()} (mkdir -p #{Ids.state_dir()} first). JSON, exactly this shape:",
        "",
        "  {",
        ~s(    "surveyed_at": "<ISO 8601 UTC, now>",),
        ~s(    "repos": ["<absolute path of each clone under /workspace>"],),
        ~s(    "worktrees": [{"path": "<absolute>", "branch": "<branch or null>", "dirty": <true|false>}]),
        "  }",
        "",
        "Then reply with one line per worktree: its path and branch. Nothing else."
      ],
      "\n"
    )
  end

  @doc """
  The suggestion chips under an empty track.

  They are prompts rather than features: each one is a thing a person would
  have typed, so pressing one is indistinguishable from typing it. Which is
  why they are here in the contract module and not in a component: changing
  what a chip says changes what the agent is asked.

  Which set depends on whether the project has a clone, which the project
  answers. It was `starters(%{has_repo: boolean()})` --- a map around one
  boolean, which is a named argument in a language that does not have them,
  and this one does: two clauses on the answer.
  """
  @spec starters(Project.t()) :: [Starter.t()]
  def starters(%Project{} = project), do: starters_for(Project.repo_path(project) != nil)

  defp starters_for(false) do
    [
      %Starter{
        label: "What is on this machine?",
        prompt: "Show me what is installed on this machine and what you can do here."
      },
      %Starter{
        label: "Set up a project",
        prompt:
          "Help me start a project in this directory. Ask me what I want before scaffolding anything."
      }
    ]
  end

  defp starters_for(true) do
    [
      %Starter{
        label: "Set up live preview",
        prompt:
          "Set up a live preview for this track. Inspect the app, configure its startup command and readiness path with the Ravix preview helper, start it, and fix any startup issues until it is Ready."
      },
      %Starter{
        label: "Review recent PRs",
        prompt:
          "Look at the pull requests merged into this repository in the last two weeks and tell me what changed, in the order that matters."
      },
      %Starter{
        label: "Improve agent instructions",
        prompt:
          "Read this repository's agent instructions (CLAUDE.md, AGENTS.md, .cursorrules — whichever exist) and suggest concrete improvements based on what the code actually looks like. Show me a diff before writing anything."
      },
      %Starter{
        label: "Fix a TODO",
        prompt:
          "Find the most worthwhile TODO or FIXME in this repository, explain why it is the one worth doing, and fix it."
      },
      %Starter{
        label: "Explain the architecture",
        prompt:
          "Walk me through how this repository is put together — the entry points, the boundaries, and anything a newcomer would get wrong."
      }
    ]
  end

  defp append_if(lines, condition, extra) do
    if condition, do: lines ++ extra, else: lines
  end
end
