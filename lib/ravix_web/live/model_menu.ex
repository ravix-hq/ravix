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
  `menuitemradio` button that pushes an event under the composer, or a
  radio input of the form around it in the dialog.
  """
  use RavixWeb, :html

  alias RavixWeb.ModelName

  attr :id, :string, required: true, doc: "the chip is `<id>-trigger`, the popover `<id>-menu`"
  attr :label, :string, required: true, doc: "the chip's accessible name and title"
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
        title={@label}
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
      role="menuitemradio"
      aria-checked={to_string(@checked)}
      title={@label}
      {@rest}
    >
      <.option_label label={@label} checked={@checked} tag={@tag} />
    </button>
    """
  end

  defp option_row(assigns) do
    ~H"""
    <label class="account-item model-option" title={@label}>
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
  attr :project_model, :string, required: true
  attr :models, :list, required: true, doc: "the catalog's models for the project's runtime"
  attr :disabled, :boolean, default: false

  @doc """
  The model under the composer, and the menu that changes it for the shown
  conversation from its next turn.

  Choosing an item hides the menu. The project's model is marked as the
  default, and choosing it puts the conversation back on whatever the
  project runs. With no catalog to offer, or while a turn runs, it is the
  plain label it used to be, or a disabled trigger.
  """
  def menu(%{models: []} = assigns) do
    ~H"""
    <span class="composer-model" title={agent_model(@runtime, @model)}>{agent_model(@runtime, @model)}</span>
    """
  end

  def menu(assigns) do
    assigns = assign(assigns, :choices, Enum.uniq(assigns.models ++ [assigns.model]))

    ~H"""
    <.chip
      id="model"
      label={agent_model(@runtime, @model)}
      class="composer-model model-trigger"
      menu_class="model-menu"
      menu_label="Model"
      sr_suffix=", change model"
      disabled={@disabled}
    >
      <p class="model-default-hint">Also your default for new threads</p>
      <.option
        :for={choice <- @choices}
        model={choice}
        checked={choice == @model}
        tag={if choice == @project_model, do: "Project default"}
        popovertarget="model-menu"
        popovertargetaction="hide"
        phx-click="set-model"
        phx-value-model={if choice == @project_model, do: "", else: choice}
      />
    </.chip>
    """
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
