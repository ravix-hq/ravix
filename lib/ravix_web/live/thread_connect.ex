defmodule RavixWeb.Live.ThreadConnect do
  @moduledoc "Inline payer connection for thread and new-track pickers."
  use Phoenix.Component
  alias Ravix.Accounts.Access

  # The payer connects their own account: the project's owner on an
  # owner-billed project, or, on a creator-billed track or a track this
  # person is opening while creator billing is on, that person. The panel
  # only ever writes the signed-in person's own credentials either way.
  def open(user, project_id, runtime, options) do
    with %{owner?: true, runtimes: choices} <- options,
         %{connected: false, enabled: true} <- Enum.find(choices, &(&1.runtime == runtime)),
         :ok <- may_connect(user, project_id, Map.get(options, :billing, :owner)) do
      %{
        runtime: runtime,
        billing: Map.get(options, :billing, :owner),
        id: "thread-connect-#{Ecto.UUID.generate()}"
      }
    else
      _ -> nil
    end
  end

  def active?(user, project_id, %{id: id} = connection, id),
    do: may_connect(user, project_id, Map.get(connection, :billing, :owner)) == :ok

  def active?(_, _, _, _), do: false

  defp may_connect(user, project_id, :creator) do
    if match?({:ok, _}, Access.project_access(user, project_id)), do: :ok, else: :error
  end

  defp may_connect(user, project_id, _owner) do
    if match?({:ok, %{role: :owner}}, Access.project_access(user, project_id)),
      do: :ok,
      else: :error
  end

  attr :options, :any, required: true
  attr :connection, :any, required: true
  attr :current_user, :any, required: true
  attr :session_hash, :string, required: true

  def panel(assigns) do
    ~H"""
    <div :if={@options && @options.owner?} class="thread-connections">
      <p
        :if={
          Map.get(@options, :billing) == :creator &&
            !Enum.any?(@options.runtimes, &(&1.connected and &1.enabled))
        }
        id="creator-connect-required"
        class="hint"
      >
        Connect Claude or Codex to start a track — you pay for its agent.
      </p>
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
