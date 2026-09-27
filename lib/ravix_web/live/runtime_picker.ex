defmodule RavixWeb.Live.RuntimePicker do
  @moduledoc "The shared runtime/model fields for a track's first or subsequent thread."
  use Phoenix.Component

  attr :options, :map, required: true
  attr :params, :map, required: true
  attr :name, :string, required: true

  def fields(assigns) do
    runtime = assigns.params["runtime"] || assigns.options.runtime
    choice = Enum.find(assigns.options.runtimes, &(&1.runtime == runtime))
    assigns = assign(assigns, runtime: runtime, models: if(choice, do: choice.models, else: []))

    ~H"""
    <label for={@name <> "-runtime"}>Agent</label>
    <select id={@name <> "-runtime"} name={@name <> "[runtime]"}>
      <option
        :for={choice <- @options.runtimes}
        value={choice.runtime}
        disabled={!choice.connected or !choice.enabled}
        selected={choice.runtime == @runtime}
      >
        {RavixWeb.AgentName.label(choice.runtime)}{availability(choice, @options)}
      </option>
    </select>
    <label for={@name <> "-model"}>Model</label>
    <select id={@name <> "-model"} name={@name <> "[model]"}>
      <option
        :for={model <- @models}
        value={model}
        selected={model == (@params["model"] || @options.model)}
      >
        {RavixWeb.ModelName.friendly(model)}
      </option>
    </select>
    """
  end

  defp availability(%{enabled: false, runtime: runtime}, _options),
    do: " — #{RavixWeb.AgentName.label(runtime)} threads on this project aren't available yet"

  defp availability(%{connected: false}, %{owner?: true}), do: " — Connect to use"

  defp availability(%{connected: false}, options),
    do: " — Not connected — #{options.owner_login} must connect it"

  defp availability(_, _), do: ""
end
