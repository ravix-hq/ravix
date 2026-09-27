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
    <label for={@name <> "-runtime"}>Runtime</label>
    <select id={@name <> "-runtime"} name={@name <> "[runtime]"}>
      <option
        :for={choice <- @options.runtimes}
        value={choice.runtime}
        disabled={!choice.connected}
        selected={choice.runtime == @runtime}
      >
        {String.capitalize(choice.runtime)}{if !choice.connected, do: " — Not connected"}
      </option>
    </select>
    <label for={@name <> "-model"}>Model</label>
    <select id={@name <> "-model"} name={@name <> "[model]"}>
      <option
        :for={model <- @models}
        value={model}
        selected={model == (@params["model"] || @options.model)}
      >
        {model}
      </option>
    </select>
    """
  end
end
