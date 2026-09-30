defmodule Ravix.Tracks.View do
  @moduledoc """
  A track as a page shows it: the row, plus what had to be asked elsewhere.

  `owner_login` identifies the project owner, independently of who created
  the track. It is taken from the already-scoped people list.

  `unread` is the rail's dot: the agent replied or somebody else commented
  since this person last looked. `reply_unread` is the agent's half alone,
  and `mention` the newest unread comment naming this person; those two are
  what the Inbox lists. `reply_unread` is nil where only the agent's side
  was read (a single `present/2`), and then means the same as `unread`.
  `reply` is the opening of the newest unread reply, as its thread kept it
  (`Ravix.Tracks.Reply`), for the Inbox card; nil until one is kept.

  `billing` is who pays for the track's agent (ADR 0009 phase 6): `:creator`
  on a creator-billed track, `:owner` otherwise; `payer_login` names them and
  `payer?` says the viewer is them. `billing_pause` is a harness paused
  because the payer's credential stopped serving, with the reason everybody
  on the track is shown; the payer's Inbox lists it.

  `model` is the model the shown conversation runs instead of its agent's,
  read live off Fountain like the status, and nil when it follows the
  project's model.

  `session_options` is the runtime's advertised ACP config options for the
  shown conversation, live off Fountain (ADR 0062), nil until a turn has
  reported them; `session_config` is the thread's own choice (RAV-52).

  `activity_at` is when anything last happened on the track, as far as
  Ravix already knows without asking again: the newest of its creation,
  opening, closing, newest accepted prompt and its conversations' last
  activity. The rail shows it as a relative age.

  Deliberately not the `Ravix.Tracks.Track` schema with extra fields on it.
  That schema argues against exactly that in its own documentation -- status,
  turn count and whether the machine is up are read live because "caching
  them here is how a UI ends up confidently showing a machine that died an
  hour ago" -- and a virtual field is still a field on the row, reading as
  nil on every track that came back from `Repo.get/2` without being
  presented. So the two shapes stay two shapes.

  What it *is* rather than the bare map it used to be is a struct, and
  `@enforce_keys` covers every field. `present/2` assembles a track from a
  row, a live conversation, a project and a read mark, and forgetting one of
  those on a new field is the mistake this makes loud: a missing key raises
  where it is built, and a misspelt one no longer compiles.
  """

  alias Ravix.People.Person
  alias Ravix.Tracks.Origin

  @typedoc """
  `:opening` until the machine answers, then whatever the conversation says.
  `:closed` outranks all of them: a closed track has no live half left.
  """
  @type status :: :opening | :setup_failed | :ready | :running | :failed | :closed

  @enforce_keys [
    :id,
    :project_id,
    :owner_login,
    :conversation_id,
    :slug,
    :title,
    :branch,
    :workdir,
    :origin,
    :status,
    :stale,
    :opened_at,
    :last_active_at,
    :turn_count,
    :created_at,
    :created_by_login,
    :people,
    :role,
    :unread,
    :model,
    :setup_state,
    :setup_attempts,
    :setup_error,
    :setup_retry_at
  ]

  defstruct @enforce_keys ++
              [
                visibility: :project,
                created_by: nil,
                creator_revoked_at: nil,
                creator_avatar_url: nil,
                activity_at: nil,
                closed_at: nil,
                sandbox_layout: :shared,
                sandbox_state: nil,
                sandbox_stage: nil,
                sandbox_action: nil,
                sandbox_suspended_at: nil,
                repo_full_name: nil,
                threads: [],
                setup_error_code: nil,
                runtime: nil,
                default_model: nil,
                session_config: %{},
                session_options: nil,
                reply_unread: nil,
                reply: nil,
                mention: nil,
                billing: :owner,
                payer_login: nil,
                payer?: false,
                billing_pause: nil,
                level: nil
              ]

  @type t :: %__MODULE__{
          id: String.t(),
          project_id: String.t(),
          owner_login: String.t(),
          conversation_id: String.t() | nil,
          slug: String.t(),
          title: String.t(),
          branch: String.t(),
          workdir: String.t(),
          origin: Origin.t(),
          status: status(),
          stale: boolean(),
          opened_at: DateTime.t() | nil,
          last_active_at: DateTime.t() | nil,
          turn_count: non_neg_integer(),
          created_at: DateTime.t(),
          created_by_login: String.t(),
          creator_avatar_url: String.t() | nil,
          activity_at: DateTime.t() | nil,
          closed_at: DateTime.t() | nil,
          people: [Person.t()],
          role: :owner | :member,
          level: Ravix.Accounts.Access.level() | nil,
          unread: boolean(),
          reply_unread: boolean() | nil,
          reply: %{excerpt: String.t(), at: DateTime.t()} | nil,
          mention: %{comment_id: String.t(), author_login: String.t(), at: DateTime.t()} | nil,
          model: String.t() | nil,
          runtime: String.t() | nil,
          default_model: String.t() | nil,
          session_config: Ravix.SessionConfig.config(),
          session_options: [Ravix.SessionConfig.Option.t()] | nil,
          threads: [map()],
          setup_state: String.t(),
          setup_attempts: non_neg_integer(),
          setup_error: String.t() | nil,
          setup_error_code: String.t() | nil,
          setup_retry_at: DateTime.t() | nil,
          sandbox_layout: :shared | :dedicated,
          sandbox_state: atom() | nil,
          sandbox_stage: String.t() | nil,
          sandbox_action: :open | :close | :rebuild | nil,
          sandbox_suspended_at: DateTime.t() | nil,
          billing: :owner | :creator,
          payer_login: String.t() | nil,
          payer?: boolean(),
          billing_pause: %{runtime: String.t(), message: String.t()} | nil
        }
end
