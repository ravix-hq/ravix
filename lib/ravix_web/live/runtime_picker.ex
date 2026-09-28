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
    <input
      type="hidden"
      name={@name <> "[preference_explicit]"}
      value={@params["preference_explicit"] || "false"}
    />
    <p :if={Map.has_key?(@options, :source)} class="thread-default-source">
      {source_label(@options.source)}: {RavixWeb.AgentName.label(@options.runtime)} · {RavixWeb.ModelName.friendly(
        @options.model
      )}
    </p>
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

  defp source_label(:person), do: "Your default"
  defp source_label(:track), do: "Track's last choice"
  defp source_label(:project), do: "Project default"

  defp availability(%{enabled: false, runtime: runtime}, _options),
    do: " — #{RavixWeb.AgentName.label(runtime)} threads on this project aren't available yet"

  defp availability(%{connected: false}, %{owner?: true}), do: " — Connect to use"

  # A creator-billed track runs on its creator's connections only; one they
  # have not made is disabled, never lent from whoever is looking.
  defp availability(%{connected: false, runtime: runtime}, %{billing: :creator} = options),
    do: " — @#{options.owner_login} hasn't connected #{RavixWeb.AgentName.label(runtime)}"

  defp availability(%{connected: false}, options),
    do: " — Not connected — #{options.owner_login} must connect it"

  defp availability(_, _), do: " — Connected"
end
