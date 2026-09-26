defmodule RavixWeb.CoreComponents do
  @moduledoc """
  The primitives every page is built from.

  Two kinds live here. The first is Phoenix's generated set (flash, button,
  input, header, table, list, icon) kept for the shape every LiveView
  tutorial assumes, restyled to the app's own stylesheet: there is no
  Tailwind in this project and no utility class anywhere, so every class
  below is a selector in `assets/css/app.css`. The second is the SPA's own
  primitives, ported from `src/components`: the dialog shell, the empty
  state and its "not configured" variant, the wordmark, and the toast that
  every error in Ravix is shown as (errors are toasts, never a replaced
  screen).

  Icons come from `RavixWeb.Icons`; `icon/1` here is the same component so
  the `<.icon>` every template already has in scope draws from that set.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc "Visible, politely announced feedback for work awaiting a response."
  attr :id, :string, default: nil
  slot :inner_block, required: true

  def loading_status(assigns) do
    ~H"""
    <p id={@id} class="loading-status" role="status">
      <span class="loading-spinner" aria-hidden="true"></span>
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  @doc "A viewer-relative project label; the context supplies ownership and plain text."
  attr :project, :map, required: true

  def project_name(assigns) do
    ~H"""
    <span class="project-label" title={@project.display_name}><span
      :if={@project.display_name != @project.name}
      class="dim"
    >{@project.owner_login} / </span>{@project.name}</span>
    """
  end

  @doc """
  A toast: one line, bottom right, with a dismiss.

  `kind` `:error` makes it `bad`, which is the red keyline; `:info` is the
  plain one. `dismiss` is the JS command the x runs (the flash-clearing
  push by default; `nil` for a toast whose lifetime is somebody else's,
  like the reconnect notice, which then has no x).

      <.toast id="flash-error" kind={:error}>Could not save.</.toast>
  """
  attr :id, :string, required: true
  attr :kind, :atom, default: :info, values: [:info, :error]

  attr :dismiss, :any,
    default: :flash,
    doc: "a JS command, a string event, `:flash` to clear the flash of this kind, or nil"

  attr :rest, :global, doc: "phx-* and `hidden` land on the toast itself"
  slot :inner_block, required: true

  def toast(assigns) do
    assigns = assign(assigns, :on_dismiss, dismiss_command(assigns.dismiss, assigns))

    ~H"""
    <div id={@id} class={["toast", @kind == :error && "bad"]} role="status" {@rest}>
      <span class="ico"><.icon name="info" size={14} /></span>
      <span>{render_slot(@inner_block)}</span>
      <button
        :if={@on_dismiss}
        type="button"
        class="x"
        aria-label="Dismiss"
        phx-click={@on_dismiss}
      >
        <.icon name="x" size={12} />
      </button>
    </div>
    """
  end

  defp dismiss_command(nil, _assigns), do: nil

  defp dismiss_command(:flash, assigns) do
    JS.push("lv:clear-flash", value: %{key: assigns.kind}) |> JS.hide(to: "##{assigns.id}")
  end

  defp dismiss_command(event, assigns) when is_binary(event),
    do: JS.push(event) |> JS.hide(to: "##{assigns.id}")

  defp dismiss_command(%JS{} = js, _assigns), do: js

  @doc """
  The flash of one kind, as a toast, when there is one.

      <.flash kind={:info} flash={@flash} />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <.toast
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      kind={@kind}
      {@rest}
    >
      {msg}
    </.toast>
    """
  end

  @doc """
  A button, or a link dressed as one.

  The stylesheet's base `button` is the default look; `variant` picks one of
  its modifiers (`primary`, `ghost`, `danger`, `linkish`, `x`).

      <.button phx-click="go" variant="primary">Send</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled form)
  attr :class, :any, default: nil
  attr :variant, :string, default: nil, values: [nil | ~w(primary ghost danger linkish x)]
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns = assign(assigns, :class, [assigns.variant, assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  A labelled input with its errors, in a `.field` row.

  A `Phoenix.HTML.FormField` may be passed, which supplies the name, id and
  value; otherwise pass them explicitly. `type="select"` renders a select
  (pass `options`), `type="textarea"` a textarea, `type="checkbox"` a boolean
  checkbox with its hidden false. `hint` is the grey line under the control.

      <.input field={@form[:name]} label="Name" hint="Shown in the rail." />
      <.input name="q" value="" placeholder="Search" />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "classes for the control itself"

  attr :rest, :global,
    include: ~w(accept autocomplete autofocus capture cols disabled form list max maxlength min
                minlength multiple pattern placeholder readonly required rows size step
                spellcheck)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field">
      <label class="row" for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class}
          {@rest}
        />
        <span>{@label}</span>
      </label>
      <span :if={@hint} class="hint">{@hint}</span>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id}>{@label}</label>
      <select id={@id} name={@name} class={@class} multiple={@multiple} {@rest}>
        <option :if={@prompt} value="">{@prompt}</option>
        {Form.options_for_select(@options, @value)}
      </select>
      <span :if={@hint} class="hint">{@hint}</span>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id}>{@label}</label>
      <textarea id={@id} name={@name} class={@class} {@rest}>{Form.normalize_value("textarea", @value)}</textarea>
      <span :if={@hint} class="hint">{@hint}</span>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="field">
      <label :if={@label} for={@id}>{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Form.normalize_value(@type, @value)}
        class={@class}
        {@rest}
      />
      <span :if={@hint} class="hint">{@hint}</span>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="error fine">{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  A heading row: the title, an optional line under it, and actions on the
  right.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={["row", @class]}>
      <div class="col" style="gap: 2px">
        <h2>{render_slot(@inner_block)}</h2>
        <p :if={@subtitle != []} class="dim fine">{render_slot(@subtitle)}</p>
      </div>
      <span class="spacer" />
      <div :if={@actions != []} class="row">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  A plain table. Streams are supported.

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}><span class="offscreen">Actions</span></th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td :for={col <- @col} phx-click={@row_click && @row_click.(row)}>
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []}>
            <div class="row">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  A list of titled rows, on keylines.

      <.list>
        <:item title="Branch">{@track.branch}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="col" style="gap: 0">
      <div :for={item <- @item} class="keyline">
        <dt class="dim">{item.title}</dt>
        <dd class="truncate" style="margin: 0 0 0 auto">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  One icon from `RavixWeb.Icons`, by name.

      <.icon name="machine" />
      <.icon name="chevron" size={13} open={@open} />
  """
  attr :name, :string, required: true, values: RavixWeb.Icons.names()
  attr :size, :integer, default: 15
  attr :class, :any, default: nil
  attr :open, :boolean, default: false, doc: "chevron only: pointing down rather than right"
  attr :rest, :global

  def icon(assigns), do: RavixWeb.Icons.icon(assigns)

  @doc "The shared, browser-local palette picker for public and workspace pages."
  attr :id, :string, required: true

  def theme_picker(assigns) do
    ~H"""
    <div id={@id} phx-hook="Theme" class="theme-picker">
      <button
        class="theme-trigger"
        data-theme-toggle
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-menu"}
      >
        <span class="theme-swatch" data-theme-swatch></span><span class="col"><small>Theme</small><span
          class="truncate"
          data-theme-name
        >Ravix</span></span>
        <.icon name="chevron" size={12} />
      </button>
      <div id={"#{@id}-menu"} class="theme-menu" role="menu" aria-label="Theme" hidden>
        <button
          :for={
            theme <-
              ~w(ravix slate one-dark dracula nord tokyo-night catppuccin-mocha night-owl monokai gruvbox-dark solarized-dark daylight github-light one-light solarized-light catppuccin-latte mario neon-noir vaporwave matrix hot-dog-stand bubblegum)
          }
          class="theme-option"
          role="menuitemradio"
          aria-checked="false"
          data-theme-choice={theme}
          data-theme-name={
            String.replace(theme, "-", " ")
            |> String.split()
            |> Enum.map_join(" ", &String.capitalize/1)
          }
        >
          <span class="theme-swatch" data-theme={theme}></span><span>{String.replace(theme, "-", " ")
          |> String.split()
          |> Enum.map_join(" ", &String.capitalize/1)}</span><span
            class="check"
            data-theme-check
            aria-hidden="true"
            hidden
          >✓</span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The owner's half of an invite dialog: mint a link, revoke it, show it once.

  Both the track dialog and the project dialog offer exactly this, and both
  had written it out, down to a private `invite_url/1` in one page and an
  `invitation_url/1` in the other. What the two copies did not share was the
  revoke button's wording, which is the kind of drift a duplicated block
  produces on its own.

  The URL is shown only in the turn it was minted in: the server keeps a hash
  and genuinely cannot show it again, so a link that is out reads as absent
  here rather than as something to be recovered. `@invite.url` and not
  `@invite[:url]`, so that a misspelling here fails instead of rendering the
  same nothing a link-with-no-URL renders.

      <.invite_link owner={@track.role == :owner} invite={@invite} />
  """
  attr :owner, :boolean, required: true, doc: "only the owner may mint or revoke"

  attr :invite, Ravix.People.InviteLink,
    default: nil,
    doc: "the link as `Ravix.People.link/2` reports it, or nil when none was read"

  attr :target, :any, default: nil, doc: "a `@myself` when the dialog is a live_component"

  def invite_link(assigns) do
    ~H"""
    <div :if={@owner}>
      <button class="ghost" phx-click="invite-link" phx-value-action="create" phx-target={@target}>
        Create invite link
      </button>
      <button class="ghost" phx-click="invite-link" phx-value-action="revoke" phx-target={@target}>
        Revoke invite link
      </button>
    </div>
    <p :if={@invite && @invite.url}>
      <a href={@invite.url}>{@invite.url}</a>
    </p>
    """
  end

  @doc """
  The shell every modal sits in (`src/components/Dialog.tsx`).

  A dialog is the one place a web app can trap somebody, so the behaviour
  lives here once: Escape and a click on the scrim run `on_close`, Tab cycles
  inside it (`focus_wrap`), and the first focusable thing gets focus when it
  mounts. Focus goes back to the opener if the opener ran `JS.push_focus/0`
  on the way in; `on_close` pops it.

  The body scrolls independently of the heading and footer, keeping long
  settings forms reachable without moving the Close button off screen.

      <.dialog id="new-project" title="New project" on_close="close">
        <form>...</form>
        <:footer><.button variant="primary">Create</.button></:footer>
      </.dialog>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_close, :any, required: true, doc: "a JS command or the name of an event to push"
  attr :wide, :boolean, default: false, doc: "for a sheet of fields rather than a list of rows"
  attr :initial_focus, :string, default: nil, doc: "selector to focus when the dialog opens"
  attr :rest, :global
  slot :inner_block, required: true
  slot :footer

  def dialog(assigns) do
    assigns = assign(assigns, :close, JS.pop_focus(command(assigns.on_close)))

    ~H"""
    <div id={@id} class="scrim" {@rest}>
      <.focus_wrap
        id={"#{@id}-dialog"}
        class="dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        tabindex="-1"
        style={@wide && "width: min(860px, 100%)"}
        phx-window-keydown={@close}
        phx-key="escape"
        phx-click-away={@close}
        phx-mounted={
          if @initial_focus,
            do: JS.focus(to: @initial_focus),
            else: JS.focus_first(to: "##{@id}-dialog")
        }
      >
        <div class="dialog-head">
          <h2 id={"#{@id}-title"}>{@title}</h2>
          <span class="spacer" />
          <button type="button" class="x" phx-click={@close} aria-label="Close">
            <.icon name="x" size={16} />
          </button>
        </div>
        <div class="dialog-body">{render_slot(@inner_block)}</div>
        <div :if={@footer != []} class="dialog-foot">{render_slot(@footer)}</div>
      </.focus_wrap>
    </div>
    """
  end

  @doc """
  The empty state, which in this app is a designed surface rather than a
  gap (`src/components/Empty.tsx`).

  It insists on three things, because a "coming soon" that leaves any of
  them out is the kind that makes people stop trusting the rest of the app:
  what it would do (the body), why it is not here (`because`), and what to
  do instead (`action`), when there is something.

      <.empty icon="machine" title="No machine yet" because="The machine is built when a project first needs one.">
        This project has nothing running to type at.
      </.empty>
  """
  attr :icon, :string, required: true, doc: "an icon name"
  attr :title, :string, required: true
  attr :because, :string, default: nil, doc: "the concrete reason, when there is one"
  attr :soon, :boolean, default: false, doc: "set for a surface that genuinely is not built yet"
  attr :rest, :global
  slot :inner_block, required: true, doc: "one or two sentences: what this panel is for"
  slot :because_block, doc: "a `because` with markup in it, instead of the attr"

  slot :action, doc: "one button" do
    attr :label, :string, required: true
    attr :click, :any, required: true
  end

  def empty(assigns) do
    ~H"""
    <div class="empty" {@rest}>
      <span class="mark"><.icon name={@icon} size={20} /></span>
      <h3>{@title}</h3>
      <p>{render_slot(@inner_block)}</p>
      <p :if={@because} class="dimmer">{@because}</p>
      <p :if={@because_block != []} class="dimmer">{render_slot(@because_block)}</p>
      <span :if={@soon} class="soon">Coming soon</span>
      <button
        :for={action <- @action}
        type="button"
        class="primary"
        style="margin-top: 6px"
        phx-click={action.click}
      >
        {action.label}
      </button>
    </div>
    """
  end

  @doc """
  A panel that is off because this deployment did not configure it.

  Distinguished from "coming soon" on purpose: this feature is built, and
  whether you have it is a decision somebody made about this server.

      <.not_configured icon="terminal" title="Terminal" variable="SPRITES_TOKEN">
        With a Sprites token, this panel runs commands on the machine.
      </.not_configured>
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :variable, :string, required: true, doc: "the environment variable that is missing"
  slot :inner_block, required: true

  def not_configured(assigns) do
    ~H"""
    <.empty icon={@icon} title={@title}>
      {render_slot(@inner_block)}
      <:because_block>
        This Ravix deployment has no <code>{@variable}</code>, so the feature is switched off here rather than unfinished.
      </:because_block>
    </.empty>
    """
  end

  @doc """
  The wordmark: the product name set in the app's own sans.

  Plain type on purpose. A drawn or pixel-grid logotype invites comparison
  with other products' marks; the typeface we already ship does not.

      <.wordmark />
      <.wordmark size={24} />
  """
  attr :text, :string, default: "Ravix"
  attr :size, :integer, default: 44, doc: "the font size, in pixels"

  def wordmark(assigns) do
    ~H"""
    <span class="wordmark" style={"font-size: #{@size}px"}>{@text}</span>
    """
  end

  ## JS Commands

  @doc "Show an element. No transition: the stylesheet animates what it wants to."
  def show(js \\ %JS{}, selector), do: JS.show(js, to: selector)

  @doc "Hide an element."
  def hide(js \\ %JS{}, selector), do: JS.hide(js, to: selector)

  # A string is the name of an event to push; a JS command is used as is.
  defp command(%JS{} = js), do: js
  defp command(event) when is_binary(event), do: JS.push(event)

  @doc """
  Translates an error message.
  """
  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
