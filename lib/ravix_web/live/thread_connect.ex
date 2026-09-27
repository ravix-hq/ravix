defmodule RavixWeb.Live.ThreadConnect do
  @moduledoc "Inline owner connection for thread and new-track pickers."
  use Phoenix.Component
  alias Ravix.Accounts.Access

  def open(user, project_id, runtime, options) do
    with %{owner?: true, runtimes: choices} <- options,
         %{connected: false, enabled: true} <- Enum.find(choices, &(&1.runtime == runtime)),
         {:ok, %{role: :owner}} <- Access.project_access(user, project_id) do
      %{runtime: runtime, id: "thread-connect-#{Ecto.UUID.generate()}"}
    else
      _ -> nil
    end
  end

  def active?(user, project_id, %{id: id}, id),
    do: match?({:ok, %{role: :owner}}, Access.project_access(user, project_id))

  def active?(_, _, _, _), do: false

  attr :options, :any, required: true
  attr :connection, :any, required: true
  attr :current_user, :any, required: true
  attr :session_hash, :string, required: true

  def panel(assigns) do
    ~H"""
    <div :if={@options && @options.owner?} class="thread-connections">
      <button
        :for={choice <- @options.runtimes}
        :if={choice.enabled && !choice.connected}
        type="button"
        class="secondary"
        phx-click="connect-thread-agent"
        phx-value-runtime={choice.runtime}
      >Connect to use {RavixWeb.AgentName.label(choice.runtime)}</button>
      <.live_component
        :if={@connection}
        module={RavixWeb.Live.AgentPanel}
        id={@connection.id}
        scoped_agent={if @connection.runtime == "codex", do: :codex, else: :claude}
        current_user={@current_user}
        session_hash={@session_hash}
      />
    </div>
    """
  end
end
