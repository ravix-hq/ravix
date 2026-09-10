defmodule Ravix.Hub do
  @moduledoc """
  One project's events, fanned out to everyone looking at it.

  The TypeScript server kept a hub of listeners and a server-sent stream per
  browser; here the hub is `Phoenix.PubSub` on a topic per project and the
  browser is a LiveView process that subscribed to it. What is published is
  the same set of facts Fountain's own conversation stream cannot know: a
  track opened, a turn finished, the settings moved, a person invited.

  A subscriber re-checks access as it handles each message. The hub does
  not: publishing is by project id and a process that lost its seat on the
  project is expected to notice on the next message and leave.

  Everything on it is a `Ravix.Hub.Event`, delivered as `{:hub, %Event{}}`,
  and the field to route on is `track_id`: a page showing one track can
  ignore an event that names a different one, and must not ignore one that
  names none. `Event.concerns?/2` is that question asked once.
  """

  alias Ravix.Hub.Event

  @doc "The topic for a project."
  @spec topic(String.t()) :: String.t()
  def topic(project_id), do: "project:" <> project_id

  @doc "Subscribe the calling process to a project's events."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(project_id), do: Phoenix.PubSub.subscribe(Ravix.PubSub, topic(project_id))

  @doc "Stop receiving a project's events."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(project_id), do: Phoenix.PubSub.unsubscribe(Ravix.PubSub, topic(project_id))

  @doc """
  Publish to everyone on a project. Delivered as `{:hub, %Ravix.Hub.Event{}}`.

  `opts` are the event's own optional fields, `:track_id` above all; see
  `Ravix.Hub.Event` for what leaving it out claims.

  Best-effort by design: a publisher's own request never fails because a
  listener went away.
  """
  @spec publish(String.t(), Event.name(), keyword()) :: :ok
  def publish(project_id, name, opts \\ []) do
    Phoenix.PubSub.broadcast(
      Ravix.PubSub,
      topic(project_id),
      {:hub, Event.new(name, project_id, opts)}
    )

    :ok
  end

  @doc """
  The same event, to this instance's subscribers only.

  For a publisher that is *already* running on every instance. `Phoenix.Presence`
  hands each node the same diff and each node calls `handle_metas/4` on it, so a
  cluster-wide broadcast from in there reaches every subscriber once per
  instance: on two nodes one presence change produced three `here` frames (#19).
  Publishing locally from a callback that already runs everywhere gets every
  subscriber exactly one.

  Not the default, and not a tuning knob. Almost everything on the hub is
  published by whichever single instance handled a request, and that must fan
  out to the whole cluster or the other instances' readers never hear it. The
  question to ask is where the *publisher* runs, not how many readers there are.
  """
  @spec publish_local(String.t(), Event.name(), keyword()) :: :ok
  def publish_local(project_id, name, opts \\ []) do
    Phoenix.PubSub.local_broadcast(
      Ravix.PubSub,
      topic(project_id),
      {:hub, Event.new(name, project_id, opts)}
    )

    :ok
  end
end
