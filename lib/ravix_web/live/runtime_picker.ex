defmodule RavixWeb.Live.RuntimePicker do
  @moduledoc "The shared agent/model pill for a track's first thread and a new thread's draft."
  use Phoenix.Component

  alias RavixWeb.Live.ModelMenu

  attr :options, :map, required: true
  attr :params, :map, required: true
  attr :name, :string, required: true
  attr :id, :string, required: true
  attr :form, :string, required: true, doc: "the form the radios belong to, from outside it"
  attr :disabled, :boolean, default: false
  attr :class, :any, default: "pick-chip", doc: "the chip's classes"
  attr :hint, :string, default: nil, doc: "a line under the menu's groups"

  attr :connect, :boolean,
    default: false,
    doc: "offer a payer's unconnected agents as `connect-thread-agent` rows"

  @doc """
  The agent and model as one `Agent · Model` chip whose menu is the
  composer's (`RavixWeb.Live.ModelMenu`): the agents, then the chosen
  agent's models, each a radio of the form, so every pick still arrives as
  its change event and `_target` marks it explicit. Choosing an agent keeps
  the menu open for its models; choosing a model closes it. Where the
  default came from is the tag on its row, not a line of its own.
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
      class={@class}
      menu_class="model-menu runtime-picker"
      menu_label="Agent and model"
      disabled={@disabled}
    >
      <fieldset class="chip-group">
        <legend>Agent</legend>
        <ModelMenu.option
          :for={choice <- @options.runtimes}
          model={choice.runtime}
          icon="terminal"
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
        <%!-- RAV-80: connecting is asked for here, beside the agent it
          unlocks, rather than by a button above the composer; the panel it
          opens is still `ThreadConnect.panel/1`'s. --%>
        <button
          :for={choice <- @options.runtimes}
          :if={@connect && @options.owner? && choice.enabled && !choice.connected}
          type="button"
          class="account-item model-option"
          phx-click="connect-thread-agent"
          phx-value-runtime={choice.runtime}
          popovertarget={"#{@id}-menu"}
          popovertargetaction="hide"
        >
          <RavixWeb.CoreComponents.icon name="plug" size={14} class="model-option-icon" />
          <span class="model-option-text"><span class="truncate">Connect {RavixWeb.AgentName.label(
            choice.runtime
          )}…</span></span>
        </button>
      </fieldset>
      <fieldset :if={@models != []} class="chip-group">
        <legend>Model</legend>
        <ModelMenu.search :if={ModelMenu.searchable?(@models)} id={@id} />
        <ModelMenu.option
          :for={model <- @models}
          filter={RavixWeb.ModelName.friendly(model)}
          model={model}
          icon="code"
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
      <p :if={@hint} class="model-default-hint">{@hint}</p>
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
