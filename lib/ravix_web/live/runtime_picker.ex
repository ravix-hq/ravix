defmodule RavixWeb.Live.RuntimePicker do
  @moduledoc "The shared runtime/model fields for a track's first or subsequent thread."
  use Phoenix.Component

  alias RavixWeb.Live.ModelMenu

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

  attr :options, :map, required: true
  attr :params, :map, required: true
  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :form, :string, required: true, doc: "the form the radios belong to, from outside it"
  attr :disabled, :boolean, default: false

  @doc """
  The same choice as `fields/1`, as one `Agent · Model` chip whose menu is
  the composer's (`RavixWeb.Live.ModelMenu`): the agents, then the chosen
  agent's models, each a radio of the form, so every pick still arrives as
  its change event and `_target` marks it explicit. Choosing an agent keeps
  the menu open for its models; choosing a model closes it.
  """
  def menu(assigns) do
    runtime = assigns.params["runtime"] || assigns.options.runtime
    choice = Enum.find(assigns.options.runtimes, &(&1.runtime == runtime))
    models = if choice, do: choice.models, else: []

    # What a select would submit: the asked-for model, else the default,
    # else the first one the agent offers.
    model =
      Enum.find([assigns.params["model"], assigns.options.model], &(&1 in models)) ||
        List.first(models)

    assigns = assign(assigns, runtime: runtime, models: models, model: model)

    ~H"""
    <input
      type="hidden"
      name={@name <> "[preference_explicit]"}
      value={@params["preference_explicit"] || "false"}
      form={@form}
    />
    <ModelMenu.chip
      id={@id}
      label={ModelMenu.agent_model(@runtime, @model || "")}
      haspopup="dialog"
      class="pick-chip"
      menu_class="model-menu"
      menu_label="Agent and model"
      disabled={@disabled}
    >
      <fieldset class="chip-group">
        <legend>Agent</legend>
        <ModelMenu.option
          :for={choice <- @options.runtimes}
          model={choice.runtime}
          label={RavixWeb.AgentName.label(choice.runtime)}
          tag={
            if !choice.connected or !choice.enabled,
              do: String.trim_leading(availability(choice, @options), " — ")
          }
          checked={choice.runtime == @runtime}
          name={@name <> "[runtime]"}
          form={@form}
          close={false}
          disabled={!choice.connected or !choice.enabled}
        />
      </fieldset>
      <fieldset :if={@models != []} class="chip-group">
        <legend>Model</legend>
        <ModelMenu.search :if={ModelMenu.searchable?(@models)} id={@id} />
        <ModelMenu.option
          :for={model <- @models}
          filter={RavixWeb.ModelName.friendly(model)}
          model={model}
          checked={model == @model}
          tag={
            if @runtime == @options.runtime and model == @options.model,
              do: source_label(Map.get(@options, :source))
          }
          name={@name <> "[model]"}
          form={@form}
        />
        <ModelMenu.search_empty :if={ModelMenu.searchable?(@models)} />
      </fieldset>
    </ModelMenu.chip>
    """
  end

  defp source_label(:person), do: "Your default"
  defp source_label(:track), do: "Track's last choice"
  defp source_label(:project), do: "Project default"
  defp source_label(nil), do: "Default"

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
