defmodule RavixWeb.Live.ModelMenu do
  @moduledoc """
  The chip-and-popover menus: the composer's model menu and the New track
  dialog's repository, sharing and agent/model chips (RAV-60), one component
  so the two surfaces cannot drift.

  `chip/1` is a real button and a native popover beside it: light dismiss
  and top-layer placement come with the popover, so a scrolling dialog body
  cannot clip it. The `ChipMenu` hook adds what the popover leaves out —
  `aria-expanded` on the chip, Escape that closes only the popover and not
  the dialog around it, focus into the popover on open and back to the chip
  on close. `option/1` is one model row, the same in both places: a
  `role="radio"` button that pushes an event under the composer, or a
  radio input of the form around it in the dialog. Both popovers are
  dialogs of radio groups (RAV-95): a menu may hold only menu items, and
  the composer's has a switch and may have a search field.
  """
  use RavixWeb, :html

  alias Ravix.SessionConfig
  alias RavixWeb.ModelName

  attr :id, :string, required: true, doc: "the chip is `<id>-trigger`, the popover `<id>-menu`"
  attr :label, :string, required: true, doc: "the chip's accessible name and title"
  attr :title, :string, default: nil, doc: "the chip's title, when it says more than its label"
  attr :haspopup, :string, default: "menu", values: ~w(menu dialog)
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil, doc: "the chip's classes"
  attr :menu_class, :any, default: nil
  attr :menu_label, :string, required: true
  attr :sr_suffix, :string, default: nil, doc: "read after the label, as \", change model\""
  attr :rest, :global, doc: "on the chip"
  slot :trigger, doc: "what the chip shows; the label when empty"
  slot :inner_block, required: true

  @doc "A chip that opens a popover."
  def chip(assigns) do
    ~H"""
    <div id={@id} class="chip-menu" phx-hook="ChipMenu">
      <button
        type="button"
        id={"#{@id}-trigger"}
        class={@class}
        popovertarget={"#{@id}-menu"}
        aria-haspopup={@haspopup}
        aria-expanded="false"
        aria-controls={"#{@id}-menu"}
        aria-label={@label}
        title={@title || @label}
        disabled={@disabled}
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        style={"anchor-name: --#{@id}"}
        {@rest}
      ><span class="truncate">{if @trigger == [], do: @label, else: render_slot(@trigger)}</span><span
        :if={@sr_suffix}
        class="sr-only"
      >{@sr_suffix}</span><.icon
        name="chevron"
        size={10}
        open={true}
      /></button>
      <div
        id={"#{@id}-menu"}
        class={["chip-popover", @menu_class]}
        popover
        role={@haspopup}
        aria-label={@menu_label}
        style={"position-anchor: --#{@id}"}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :model, :string, required: true, doc: "the value: a model, or a runtime"
  attr :label, :string, default: nil, doc: "the model's friendly name when empty"
  attr :checked, :boolean, required: true
  attr :tag, :string, default: nil, doc: "marks the default, as \"Project default\""
  attr :icon, :string, default: nil
  attr :name, :string, default: nil, doc: "a radio input of this name, instead of a button"
  attr :form, :string, default: nil
  attr :close, :boolean, default: true, doc: "whether picking the radio closes the menu"
  attr :filter, :string, default: nil, doc: "what a model search matches this row by"
  attr :rest, :global, include: ~w(popovertarget popovertargetaction disabled)

  @doc "One model in a model menu."
  def option(assigns) do
    assigns = assign(assigns, :label, assigns.label || ModelName.friendly(assigns.model))
    option_row(assigns)
  end

  defp option_row(%{name: nil} = assigns) do
    ~H"""
    <button
      type="button"
      class="account-item model-option"
      role="radio"
      aria-checked={to_string(@checked)}
      title={@label}
      data-filter-text={@filter}
      {@rest}
    >
      <.option_label label={@label} checked={@checked} tag={@tag} icon={@icon} />
    </button>
    """
  end

  defp option_row(assigns) do
    ~H"""
    <label class="account-item model-option" title={@label} data-filter-text={@filter}>
      <input
        type="radio"
        class="sr-only"
        name={@name}
        value={@model}
        form={@form}
        checked={@checked}
        data-chip-close={@close}
        {@rest}
      />
      <.option_label label={@label} checked={@checked} tag={@tag} icon={@icon} />
    </label>
    """
  end

  attr :label, :string, required: true
  attr :checked, :boolean, required: true
  attr :tag, :string, required: true
  attr :icon, :string, required: true

  defp option_label(assigns) do
    ~H"""
    <.icon :if={@icon} name={@icon} size={14} class="model-option-icon" />
    <span class="model-option-text"><span class="truncate">{@label}</span><small :if={@tag}>{@tag}</small></span><.icon
      name="check"
      size={14}
      class={["check", !@checked && "model-check-empty"]}
    />
    """
  end

  attr :runtime, :string, default: nil
  attr :model, :string, required: true, doc: "what the shown conversation runs"

  attr :session_options, :list,
    default: nil,
    doc: "the runtime's advertised ACP options (`Ravix.SessionConfig`), nil when unknown"

  attr :session_config, :map, default: %{}, doc: "the thread's chosen option values"
  attr :project_model, :string, required: true
  attr :models, :list, required: true, doc: "the catalog's models for the project's runtime"

  attr :runtime_options, :map,
    default: nil,
    doc: "all runtimes and models available for new threads"

  attr :disabled, :boolean, default: false
  attr :busy, :boolean, default: false, doc: "a turn is running, which is why it is disabled"

  @doc """
  The model under the composer, and the menu that changes it for the shown
  conversation from its next turn.

  Choosing an item hides the menu. The project's model is marked as the
  default, and choosing it puts the conversation back on whatever the
  project runs. With no catalog to offer, or while a turn runs, it is the
  plain label it used to be, or a disabled trigger. A turn in progress
  (RAV-87) keeps the label at full contrast and says in the title why it
  cannot change, rather than greying out without a reason.

  Effort and Fast (RAV-52) come from what the runtime advertised on the
  conversation's latest turn (Fountain ADR 0062): the `thought_level`
  select, with the adapter's own values and names, and a Fast toggle. Which
  models offer them is the adapter's to say, so nothing here lists models.
  Before any turn has reported, or on a Fountain without the field, neither
  is shown and the label is the model alone.

  Models stay in a searchable flat list. Effort expands below it; Fast is
  a switch, disabled when the runtime reports no Fast option for this model.
  """
  def menu(%{models: []} = assigns) do
    assigns = assign(assigns, :label, chip_label(assigns))

    ~H"""
    <span class="composer-model" title={@label}>{@label}</span>
    """
  end

  def menu(assigns) do
    %{effort: effort, fast: fast} = SessionConfig.controls(assigns.session_options)
    effort_value = SessionConfig.in_force(effort, assigns.session_config)
    effort_choice = effort && Enum.find(effort.choices, &(&1.value == effort_value))

    next_effort =
      if effort && effort.choices != [] do
        index = Enum.find_index(effort.choices, &(&1.value == effort_value))
        Enum.at(effort.choices, rem((index || -1) + 1, length(effort.choices)))
      end

    assigns =
      assigns
      |> assign(:groups, model_groups(assigns))
      |> assign(:effort, effort)
      |> assign(:effort_value, effort_value)
      |> assign(:effort_choice, effort_choice)
      |> assign(:next_effort, next_effort)
      |> assign(:fast, fast)
      |> assign(:speed?, is_list(assigns.session_options))
      |> assign(
        :fast_on?,
        SessionConfig.on?(SessionConfig.in_force(fast, assigns.session_config))
      )
      |> assign(:label, chip_label(assigns))

    ~H"""
    <.chip
      id="model"
      label={@label}
      class="composer-model model-trigger"
      haspopup="dialog"
      menu_class="model-menu"
      menu_label="Model"
      sr_suffix=", change model"
      disabled={@disabled}
      title={if @busy, do: "#{@label}\nCan't change while the agent is working"}
      data-busy={@busy}
      phx-click="model-options"
      phx-focus="model-options"
    >
      <.search id="model" />
      <div id="model-families" role="group" aria-label="Model families">
        <div
          :for={group <- @groups}
          id={if group.current?, do: "model-models", else: "model-models-#{group.runtime}"}
          role={if group.current?, do: "radiogroup", else: "group"}
          aria-label={group.label}
        >
          <p class="model-section-label">{group.label}</p>
          <.option
            :for={choice <- group.models}
            :if={group.current?}
            model={choice}
            icon="code"
            checked={choice == @model}
            tag={if choice == @project_model, do: "Project default"}
            popovertarget="model-menu"
            popovertargetaction="hide"
            phx-click="set-model"
            phx-value-model={if choice == @project_model, do: "", else: choice}
            filter={group.label <> " " <> ModelName.friendly(choice)}
            disabled={@disabled}
          />
          <.new_thread_option
            :for={choice <- group.models}
            :if={!group.current?}
            runtime={group.runtime}
            model={choice}
            enabled={group.available? && !@disabled}
            tag={if group.available?, do: "New thread", else: group.reason}
          />
        </div>
        <p :if={@runtime_options == nil} class="model-default-hint model-loading">
          Open to load other agents.
        </p>
        <.search_empty />
      </div>
      <details
        :if={@effort}
        id="model-effort"
        class="model-effort"
      >
        <summary class="account-item model-effort-trigger">
          <span id="model-effort-label">Effort</span><span class="spacer"></span><small>
            {if @effort_choice, do: @effort_choice.name}
          </small><.icon name="chevron" size={11} />
        </summary>
        <div role="radiogroup" aria-labelledby="model-effort-label">
          <.option
            :for={choice <- @effort.choices}
            model={choice.value}
            label={choice.name}
            checked={choice.value == @effort_value}
            popovertarget="model-menu"
            popovertargetaction="hide"
            phx-click="set-session-option"
            phx-value-id={@effort.id}
            phx-value-choice={choice.value}
            disabled={@disabled}
          />
        </div>
      </details>
      <div :if={@speed?} id="model-speed" role="group" aria-labelledby="model-speed-label">
        <span id="model-speed-label" class="sr-only">Speed</span>
        <.fast_switch fast={@fast} on?={@fast_on?} disabled={@disabled} />
      </div>
      <div class="model-menu-footer">
        <.link navigate="/settings/agents" class="ghost" data-leaves-page>
          <.icon name="settings" size={12} />Edit agents
        </.link>
        <button
          :if={@next_effort}
          type="button"
          id="model-cycle-effort"
          class="ghost"
          phx-click="set-session-option"
          phx-value-id={@effort.id}
          phx-value-choice={@next_effort.value}
          disabled={@disabled}
          data-tip={"Use #{@next_effort.name} effort"}
        >
          Cycle effort
        </button>
      </div>
      <p class="model-default-hint">Also your default for new threads</p>
    </.chip>
    """
  end

  attr :runtime, :string, required: true
  attr :model, :string, required: true
  attr :enabled, :boolean, required: true
  attr :tag, :string, default: nil

  defp new_thread_option(assigns) do
    assigns = assign(assigns, :label, ModelName.friendly(assigns.model))

    ~H"""
    <button
      type="button"
      class="account-item model-option"
      title={@label}
      data-filter-text={RavixWeb.AgentName.label(@runtime) <> " " <> @label}
      disabled={!@enabled}
      popovertarget="model-menu"
      popovertargetaction="hide"
      phx-click="draft-thread"
      phx-value-runtime={@runtime}
      phx-value-model={@model}
    >
      <.icon name="code" size={14} class="model-option-icon" />
      <span class="model-option-text"><span class="truncate">{@label}</span><small :if={@tag}>{@tag}</small></span><.icon
        :if={@enabled}
        name="external"
        size={13}
      />
    </button>
    """
  end

  attr :fast, :any,
    required: true,
    doc: "the advertised Fast option, nil when this model has none"

  attr :on?, :boolean, required: true
  attr :disabled, :boolean, default: false

  # A switch that stays in the open menu and shows its state. A model the
  # runtime offers no Fast for keeps the row, off and disabled, and says why
  # (`aria-disabled`, so the tooltip still shows and it can be focused).
  defp fast_switch(%{fast: nil} = assigns) do
    ~H"""
    <button
      id="model-fast"
      type="button"
      class="account-item model-option model-fast"
      role="switch"
      aria-checked="false"
      aria-disabled="true"
      title="Not available for this model"
      data-tip="Not available for this model"
    >
      <span class="truncate">Fast mode</span><span class="spacer"></span><span
        class="model-switch"
        aria-hidden="true"
      ></span>
    </button>
    """
  end

  defp fast_switch(assigns) do
    ~H"""
    <button
      id="model-fast"
      type="button"
      class="account-item model-option model-fast"
      role="switch"
      aria-checked={to_string(@on?)}
      phx-click="set-session-option"
      phx-value-id={@fast.id}
      phx-value-choice={to_string(!@on?)}
      disabled={@disabled}
    >
      <span class="truncate">{@fast.name}</span><span class="spacer"></span><span
        class="model-switch"
        aria-hidden="true"
      ></span>
    </button>
    """
  end

  @doc "Whether a model menu offering `models` gets a search field: more than six."
  def searchable?(models), do: length(models) > 6

  defp model_groups(assigns) do
    current = current_group(assigns)

    other_groups =
      case assigns.runtime_options do
        %{runtimes: runtimes} ->
          runtimes
          |> Enum.reject(&(&1.runtime == assigns.runtime))
          |> Enum.map(&runtime_group/1)

        _ ->
          []
      end

    [current | other_groups]
  end

  defp current_group(assigns) do
    models =
      case assigns.runtime_options do
        %{runtimes: runtimes} ->
          runtimes
          |> Enum.find(&(&1.runtime == assigns.runtime))
          |> case do
            %{models: models} -> models
            _ -> assigns.models
          end

        _ ->
          assigns.models
      end

    %{
      runtime: assigns.runtime,
      label: RavixWeb.AgentName.label(assigns.runtime) || "Agent",
      current?: true,
      available?: true,
      reason: nil,
      models: Enum.uniq(models ++ [assigns.model] ++ List.wrap(assigns.project_model))
    }
  end

  defp runtime_group(choice) do
    %{
      runtime: choice.runtime,
      label: RavixWeb.AgentName.label(choice.runtime) || choice.runtime,
      current?: false,
      available?: choice.connected && choice.enabled && choice.models != [],
      reason: unavailable_reason(choice),
      models: choice.models
    }
  end

  defp unavailable_reason(%{enabled: false}), do: "Unavailable"
  defp unavailable_reason(%{connected: false}), do: "Not connected"
  defp unavailable_reason(%{models: []}), do: "No models"
  defp unavailable_reason(_), do: nil

  attr :id, :string, required: true, doc: "the chip's id; the field is `<id>-search`"

  @doc """
  The field that narrows a long model list (RAV-95). The `ChipMenu` hook
  hides the rows (`data-filter-text`) that do not match; the server never
  hears of it, and Enter picks the first row left.
  """
  def search(assigns) do
    ~H"""
    <div class="model-search-row">
      <.icon name="search" size={13} />
      <input
        id={"#{@id}-search"}
        type="search"
        class="model-search"
        placeholder="Search models"
        aria-label="Search models"
        autocomplete="off"
        data-chip-filter
        data-chip-focus
      />
    </div>
    """
  end

  @doc "What a search that matched no model says."
  def search_empty(assigns) do
    ~H"""
    <p class="model-search-empty" data-chip-filter-empty hidden>No models match</p>
    """
  end

  # `Agent · Model`, then whatever Effort and Fast are set to (RAV-52).
  defp chip_label(assigns) do
    [agent_model(assigns.runtime, assigns.model)]
    |> Enum.concat(SessionConfig.summary(assigns.session_options, assigns.session_config))
    |> Enum.join(" · ")
  end

  @doc "`Agent · Model`, as a chip or the composer shows them."
  def agent_model(nil, model) when is_binary(model) and model != "",
    do: ModelName.friendly(model)

  def agent_model(runtime, model) do
    [RavixWeb.AgentName.label(runtime) || "Agent", ModelName.friendly(model)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end
end
