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
      <.option_label label={@label} checked={@checked} tag={@tag} />
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
      <.option_label label={@label} checked={@checked} tag={@tag} />
    </label>
    """
  end

  attr :label, :string, required: true
  attr :checked, :boolean, required: true
  attr :tag, :string, required: true

  defp option_label(assigns) do
    ~H"""
    <span class="truncate">{@label}</span><small :if={@tag}>{@tag}</small><span class="spacer"></span><span
      :if={@checked}
      class="check"
      aria-hidden="true"
    >✓</span>
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

  RAV-95 laid it out in sections, Model, Effort and Speed, with Fast as a
  switch: once the runtime has reported, a model it lists no Fast for shows
  the switch off and disabled, "Not available for this model". More than
  six models get a search field.
  """
  def menu(%{models: []} = assigns) do
    assigns = assign(assigns, :label, chip_label(assigns))

    ~H"""
    <span class="composer-model" title={@label}>{@label}</span>
    """
  end

  def menu(assigns) do
    %{effort: effort, fast: fast} = SessionConfig.controls(assigns.session_options)

    assigns =
      assigns
      |> assign(:choices, Enum.uniq(assigns.models ++ [assigns.model]))
      |> assign(:effort, effort)
      |> assign(:effort_value, SessionConfig.in_force(effort, assigns.session_config))
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
    >
      <.search :if={searchable?(@choices)} id="model" />
      <div id="model-models" role="radiogroup" aria-labelledby="model-models-label">
        <p id="model-models-label" class="model-section-label">Model</p>
        <.option
          :for={choice <- @choices}
          model={choice}
          checked={choice == @model}
          tag={if choice == @project_model, do: "Project default"}
          popovertarget="model-menu"
          popovertargetaction="hide"
          phx-click="set-model"
          phx-value-model={if choice == @project_model, do: "", else: choice}
          filter={ModelName.friendly(choice)}
        />
        <.search_empty :if={searchable?(@choices)} />
      </div>
      <div
        :if={@effort}
        id="model-effort"
        role="radiogroup"
        aria-labelledby="model-effort-label"
      >
        <p id="model-effort-label" class="model-section-label">Effort</p>
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
        />
      </div>
      <div :if={@speed?} id="model-speed" role="group" aria-labelledby="model-speed-label">
        <p id="model-speed-label" class="model-section-label">Speed</p>
        <.fast_switch fast={@fast} on?={@fast_on?} />
      </div>
      <p class="model-default-hint">Also your default for new threads</p>
    </.chip>
    """
  end

  attr :fast, :any,
    required: true,
    doc: "the advertised Fast option, nil when this model has none"

  attr :on?, :boolean, required: true

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

  attr :id, :string, required: true, doc: "the chip's id; the field is `<id>-search`"

  @doc """
  The field that narrows a long model list (RAV-95). The `ChipMenu` hook
  hides the rows (`data-filter-text`) that do not match; the server never
  hears of it, and Enter picks the first row left.
  """
  def search(assigns) do
    ~H"""
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
