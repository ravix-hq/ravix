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
  """

  @type event :: %{event: String.t(), data: term()}

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
  Publish to everyone on a project. Delivered as `{:hub, %{event: name, data: data}}`.

  Best-effort by design: a publisher's own request never fails because a
  listener went away.
  """
  @spec publish(String.t(), String.t(), term()) :: :ok
  def publish(project_id, event, data \\ %{}) do
    Phoenix.PubSub.broadcast(Ravix.PubSub, topic(project_id), {:hub, %{event: event, data: data}})
    :ok
  end
end
