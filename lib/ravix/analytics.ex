defmodule Ravix.Analytics do
  @moduledoc """
  Ravix's one door onto PostHog (ADR 0004).

  Contexts call `track/3`; nothing else in `lib/` names `PostHog`. The reasons
  are the tracing half's reasons, so `Ravix.Redact` is shared with it --- a
  property map and a span attribute map are the same hazard and go through the
  same rule. What is different here is what the events *mean*, and that is what
  the rest of this is about.

  ## Server-side only

  There is no `posthog-js`, no autocapture and no session replay, and that is a
  safety decision rather than a preference: this application renders agent
  transcripts, terminal output, file listings and diffs, which is to say the
  customer's source code. A replay would ship it to a third party behind a
  masking configuration that has to be right every time a template changes.

  So every event is captured here, from a context, where the code already knows
  who did what and can decide what to say about it. LiveView already knows which
  page somebody is on, so nothing is lost by not asking a browser.

  ## What is sent about a person

  `distinct_id` is the Ravix user id: a UUID, stable across a GitHub rename, and
  meaningless outside this deployment. Person properties are the GitHub login and
  the account's creation date, set through `$set`, and **not** the email address
  --- a login is already public, an email is a personal identifier that this
  application has no product reason to hand over.

  ## What is sent about an event

  Never prompt text, never transcript content, never a file path, never a diff,
  never a terminal command line. Those are the customer's code and the
  customer's words, and none of them answers a product question that shape does
  not: a prompt's *length* and image count say what a prompt body would, and
  `Ravix.Sprites.exec/4` already carries an argument count and never the
  arguments for the same reason.

  **Repository and branch names are the exception, and it is a deliberate one.**
  They are sent, because "which repository was this?" is the first question of
  every support conversation and no proxy answers it. They are also private
  repository names belonging to customers, travelling to a third party, which is
  a real cost accepted with open eyes rather than an oversight. If that trade
  ever looks wrong, `repo/2` below is the single place it is made.

  `Ravix.Redact.flat/1` is a backstop under all of that, not the judgement
  itself: a prompt body is a short text binary and would survive it. Keeping one
  out is the call site's job.

  ## Failure

  Nothing here can fail a request. `track/3` answers `:ok` whether PostHog is
  configured, unconfigured, unreachable or broken, and the SDK's own senders
  batch asynchronously, so a context call does not wait on a network. An
  analytics call that can break the thing it is measuring is worse than no
  analytics, which is the same rule `Ravix.Trace` follows.
  """

  require Logger

  alias Ravix.Accounts.User
  alias Ravix.Projects.Project
  alias Ravix.Redact
  alias Ravix.Tracks.Track

  @typedoc """
  Event names are past-tense and spelled out, because they are read in a
  PostHog funnel by somebody who did not write them.
  """
  @type event ::
          :signed_in
          | :agent_connected
          | :onboarding_finished
          | :project_created
          | :track_opened
          | :track_closed
          | :prompt_sent
          | :prompt_delivered
          | :preview_started
          | :preview_failed

  @events [
    signed_in: "signed in",
    agent_connected: "agent connected",
    onboarding_finished: "onboarding finished",
    project_created: "project created",
    track_opened: "track opened",
    track_closed: "track closed",
    prompt_sent: "prompt sent",
    prompt_delivered: "prompt delivered",
    preview_started: "preview started",
    preview_failed: "preview failed"
  ]

  @doc """
  Record that `user` did `event`, with `properties`.

  Always `:ok`. A context that calls this must not branch on the result, and
  there is nothing to branch on.

      Analytics.track(user, :track_opened, %{"ravix.runtime" => project.runtime})

  The event name is an atom here and a sentence in PostHog, so the spelling cannot
  drift between two call sites. A name that is not in `@events` **raises**, which
  is the one thing in this module that does: an unknown name is a programmer error
  and the alternative is a funnel step that silently never fires. A failure
  talking to PostHog is a different matter and is swallowed.
  """
  @spec track(User.t() | nil, event(), Redact.fields()) :: :ok
  def track(user, event, properties \\ %{})

  # No user, no event. Every event this application has is somebody's, and an
  # anonymous one would create a person in PostHog for nobody.
  def track(nil, _event, _properties), do: :ok

  def track(%User{} = user, event, properties) when is_atom(event) do
    # Outside the `try` on purpose. An unknown event name is a *programmer*
    # error and must raise, loudly, in the test that introduced it -- swallowing
    # it here would produce precisely the silent miss this atom exists to
    # prevent, a funnel step that never fires and nothing to say why. Only the
    # call to a third party below is protected.
    name = Keyword.fetch!(@events, event)
    properties = properties(user, properties)

    try do
      PostHog.bare_capture(name, user.id, properties)
      :ok
    rescue
      # The SDK is unconfigured, mid-restart, or has changed under us. None of
      # those is a reason for a request to fail; see the moduledoc.
      error ->
        Logger.warning("ravix: analytics #{event} dropped: #{Exception.message(error)}")
        :ok
    end
  end

  @doc """
  The repository and branch of a track, as event properties.

  The one place the decision to send repository names is made, so that changing
  it is one edit rather than an audit. See the moduledoc on what that trade is.
  """
  @spec repo(Track.t() | nil, Project.t() | nil) :: Redact.fields()
  def repo(track, project) do
    %{}
    |> put_present("ravix.repo", project && project.repo_full_name)
    |> put_present("ravix.branch", track && track.branch)
  end

  @doc """
  How long something took, in milliseconds, from a `DateTime` to now.

  For `prompt delivered`, whose useful number is the wait between a prompt being
  accepted and reaching the agent --- the thing somebody complaining about a slow
  agent is actually describing.
  """
  @spec waited_ms(DateTime.t() | nil) :: Redact.fields()
  def waited_ms(nil), do: %{}

  def waited_ms(%DateTime{} = from),
    do: %{"ravix.waited_ms" => DateTime.diff(DateTime.utc_now(), from, :millisecond)}

  # Person properties travel on every event rather than through a separate
  # `$identify`: one call site, and a person whose login changed is corrected by
  # their next action instead of only at their next sign-in. `$set_once` for the
  # creation date, which is a fact about the account and not about today.
  defp properties(%User{} = user, properties) do
    properties
    |> Redact.flat()
    |> Map.put(:"$set", Redact.flat(%{"ravix.login" => user.login}))
    |> Map.put(:"$set_once", Redact.flat(%{"ravix.created_at" => iso(user.created_at)}))
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
