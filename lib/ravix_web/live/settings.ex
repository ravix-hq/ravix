defmodule RavixWeb.Live.Settings do
  @moduledoc """
  The settings frame (RAV-72, RAV-38 decisions 2 and 4): what every settings
  page shares, whoever's settings it shows.

  Settings are pages in the app shell, one URL a section, so the browser's
  back and forward move between them:

    * `/settings/:section`, the signed-in person's own
      (`RavixWeb.Live.PersonalSettings`);
    * `/w/:workspace/settings/:section`, a workspace's
      (`RavixWeb.Live.WorkspaceSettings`);
    * `/p/:project/settings/:section`, a project's
      (`RavixWeb.Live.ProjectSettings`).

  `RavixWeb.WorkspaceLive` owns the routes and the shell, and renders the
  kind's page component; the component authorizes, loads, and draws itself
  inside `frame/1`: a grouped section nav, with Danger zone last and drawn
  as destructive, a breadcrumb, and the section's title.

  `unsaved_changes/1` is the save model (decision 2): one Save a page, in a
  sticky "Unsaved changes · Discard / Save" bar, and a confirmation before
  leaving a page with changes on it. A page opts in by wrapping its form in
  it; see that function for the API.

  The section lists below are the one place a section's URL and label are
  spelled. They are static, so the page can decide a URL before anything
  is loaded, and `resolve/3` sends a URL for a section that is not there
  (a project's Workspace section while workspaces are off) to the first.
  """
  use RavixWeb, :html

  @personal [{"connected-apps", "Connected apps"}]
  @workspace [{"general", "General"}, {"members", "Members"}]
  @project [
    {"general", "General"},
    {"agent", "Agent"},
    {"workspace", "Workspace"},
    {"environment", "Environment"},
    {"variables", "Environment variables"},
    {"secrets", "Secrets"},
    {"run-script", "Run script"},
    {"danger", "Danger zone"}
  ]

  @typedoc "Whose settings: the signed-in person's, a workspace's or a project's."
  @type kind :: :personal | :workspace | :project

  @typedoc "One link in the section nav."
  @type item :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:path) => String.t(),
          optional(:count) => non_neg_integer() | nil,
          optional(:danger) => boolean()
        }

  @typedoc "A labelled group of links; a nil label draws none."
  @type group :: %{label: String.t() | nil, items: [item()]}

  @doc "The sections of `kind`, as `{key, label}`, in nav order."
  @spec sections(kind()) :: [{String.t(), String.t()}]
  def sections(:personal), do: @personal
  def sections(:workspace), do: @workspace
  def sections(:project), do: @project

  @doc "Whether `key` names a section of `kind`."
  @spec section?(kind(), term()) :: boolean()
  def section?(kind, key), do: List.keymember?(sections(kind), key, 0)

  @doc "Where `kind`'s settings open: its first section."
  @spec first(kind()) :: String.t()
  def first(kind), do: kind |> sections() |> hd() |> elem(0)

  @doc "A section's label."
  @spec label(kind(), String.t()) :: String.t()
  def label(kind, key) do
    case List.keyfind(sections(kind), key, 0) do
      {_key, label} -> label
      nil -> "Settings"
    end
  end

  @doc "The path of one section."
  @spec section_path(kind(), String.t() | nil, String.t()) :: String.t()
  def section_path(:personal, _id, key), do: "/settings/#{key}"
  def section_path(:workspace, id, key), do: "/w/#{id}/settings/#{key}"
  def section_path(:project, id, key), do: "/p/#{id}/settings/#{key}"

  @doc ~S'The browser title: "Members · Ravi · Ravix".'
  @spec page_title(kind(), String.t(), String.t()) :: String.t()
  def page_title(kind, key, scope), do: "#{label(kind, key)} · #{scope} · Ravix"

  @doc """
  The personal group, which every personal and workspace settings page
  lists first: the person is somebody wherever they are.
  """
  @spec you_group() :: group()
  def you_group,
    do: %{label: "You", items: Enum.map(@personal, &item(:personal, nil, &1))}

  @doc """
  A workspace's group, named for it. `counts` maps a section key to the
  number its link shows, where one is useful.
  """
  @spec workspace_group(%{id: String.t(), name: String.t()}, map()) :: group()
  def workspace_group(workspace, counts \\ %{}),
    do: %{
      label: workspace.name,
      items: Enum.map(@workspace, &item(:workspace, workspace.id, &1, counts))
    }

  @doc """
  A project's groups: the project, its machine, then Danger zone alone and
  last. `shown` lists the section keys the page can show.
  """
  @spec project_groups(%{id: String.t(), display_name: String.t()}, [String.t()], map()) ::
          [group()]
  def project_groups(project, shown, counts \\ %{}) do
    items =
      for {key, _label} = section <- @project,
          key in shown,
          into: %{},
          do: {key, item(:project, project.id, section, counts)}

    [
      {project.display_name, ~w(general agent workspace)},
      {"Machine", ~w(environment variables secrets run-script)},
      {nil, ~w(danger)}
    ]
    |> Enum.map(fn {label, keys} ->
      %{label: label, items: keys |> Enum.map(&items[&1]) |> Enum.reject(&is_nil/1)}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  @typedoc "The settings page a URL opens: whose, which section, and the id of whose."
  @type page :: %{kind: kind(), section: String.t(), id: String.t() | nil}

  @doc """
  What a settings URL opens, decided from what the shell holds: the page,
  somewhere else to send the browser with a sentence saying why, `:wait`
  while the project it names is not in hand yet, or nil for a URL that is
  not a settings page at all.

  A workspace's settings are for its live members (`Workspaces.get/2`,
  which is `Access.workspace_access/2`), and only while workspaces are on;
  a project's for its owner, as the dialog was.
  """
  @spec resolve(atom(), map(), map()) ::
          {:ok, page()} | {:redirect, String.t(), String.t()} | :wait | nil
  def resolve(:user_settings, %{"section" => section}, _assigns) do
    if section?(:personal, section),
      do: {:ok, %{kind: :personal, section: section, id: nil}},
      else:
        {:redirect, section_path(:personal, nil, first(:personal)), "Settings page not found."}
  end

  def resolve(:workspace_settings, %{"workspace" => id, "section" => section}, assigns) do
    with true <- Ravix.Workspaces.enabled?(),
         {:ok, %{workspace: workspace}} <- Ravix.Workspaces.get(assigns.current_user, id) do
      if section?(:workspace, section),
        do: {:ok, %{kind: :workspace, section: section, id: workspace.id}},
        else:
          {:redirect, section_path(:workspace, workspace.id, first(:workspace)),
           "Settings page not found."}
    else
      _ -> {:redirect, "/home", "Workspace not found."}
    end
  end

  def resolve(:project_settings, _params, %{project: nil}), do: :wait

  def resolve(:project_settings, %{"section" => section}, %{project: project}) do
    cond do
      project.access == :tracks or project.role != :owner ->
        {:redirect, "/p/#{project.id}", "Only the project's owner can change its settings."}

      # The Workspace section is only there while workspaces are on.
      not section?(:project, section) or
          (section == "workspace" and not Ravix.Workspaces.enabled?()) ->
        {:redirect, section_path(:project, project.id, first(:project)),
         "Settings page not found."}

      true ->
        {:ok, %{kind: :project, section: section, id: project.id}}
    end
  end

  def resolve(_action, _params, _assigns), do: nil

  attr :settings, :map, required: true, doc: "a `t:page/0`"
  attr :project, :map, default: nil
  attr :workspace, :map, default: nil, doc: "the current workspace, for the personal nav"
  attr :current_user, :map, required: true
  attr :session_hash, :string, required: true

  @doc "The page component for `settings`, as `RavixWeb.WorkspaceLive` renders it."
  def page(assigns) do
    ~H"""
    <.live_component
      :if={@settings.kind == :project && @project && @project.id == @settings.id}
      module={RavixWeb.Live.ProjectSettings}
      id={"project-settings-#{@project.id}"}
      project={@project}
      section={@settings.section}
      current_user={@current_user}
      session_hash={@session_hash}
    />
    <.live_component
      :if={@settings.kind == :workspace}
      module={RavixWeb.Live.WorkspaceSettings}
      id="workspace-settings-page"
      workspace_id={@settings.id}
      section={@settings.section}
      current_user={@current_user}
      session_hash={@session_hash}
    />
    <.live_component
      :if={@settings.kind == :personal}
      module={RavixWeb.Live.PersonalSettings}
      id="personal-settings-page"
      section={@settings.section}
      workspace={@workspace}
      current_user={@current_user}
      session_hash={@session_hash}
    />
    """
  end

  defp item(kind, id, {key, label}, counts \\ %{}),
    do: %{
      key: key,
      label: label,
      path: section_path(kind, id, key),
      count: Map.get(counts, key),
      danger: key == "danger"
    }

  attr :id, :string, default: "settings-page"
  attr :kind, :atom, required: true, values: [:personal, :workspace, :project]
  attr :section, :string, required: true
  attr :crumbs, :list, required: true, doc: "what the page belongs to, outermost first"
  attr :nav, :list, required: true, doc: "`t:group/0`s, in order"
  slot :inner_block, required: true

  @doc """
  The frame: breadcrumb, section nav and the section's title over the
  page's own content.

      <Settings.frame kind={:workspace} section="members" crumbs={["Ravi"]}
        nav={[Settings.you_group(), Settings.workspace_group(workspace)]}>
        ...
      </Settings.frame>

  The breadcrumb ends "Settings › <section>"; `crumbs` are what comes
  before it. Every nav link patches: the shell and the page component stay
  mounted, and the URL is the section.
  """
  def frame(assigns) do
    assigns = assign(assigns, title: label(assigns.kind, assigns.section))

    ~H"""
    <div
      id={@id}
      class="settings-page"
      phx-hook="SettingsFrame"
      data-kind={@kind}
      data-section={@section}
    >
      <nav class="settings-crumbs" aria-label="Breadcrumb">
        <ol>
          <li :for={crumb <- @crumbs}>{crumb}</li>
          <li>Settings</li>
          <li aria-current="page">{@title}</li>
        </ol>
      </nav>
      <div class="settings-frame">
        <nav class="settings-section-nav" aria-label="Settings sections">
          <div
            :for={{group, index} <- Enum.with_index(@nav)}
            class={["settings-group", Enum.any?(group.items, & &1.danger) && "danger"]}
          >
            <h2 :if={group.label} id={"settings-group-#{index}"} class="settings-group-label">
              {group.label}
            </h2>
            <ul aria-labelledby={group.label && "settings-group-#{index}"}>
              <li :for={item <- group.items}>
                <.link
                  id={"settings-nav-#{item.key}"}
                  patch={item.path}
                  class={["settings-link", item.danger && "danger"]}
                  aria-current={if item.key == @section, do: "page"}
                >
                  <span class="truncate">{item.label}</span>
                  <span :if={item.count not in [nil, 0]} class="settings-count">{item.count}</span>
                </.link>
              </li>
            </ul>
          </div>
        </nav>
        <div class="settings-body">
          <h1 id="settings-title" tabindex="-1">{@title}</h1>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :form, :string, default: nil, doc: "the id of the form the bar's Save submits"
  attr :save_label, :string, default: "Save", doc: ~s|"Save & rebuild" on the Machine page|
  attr :saved, :any, default: 0, doc: "bumped by the page on every successful save"
  attr :bar, :boolean, default: true, doc: "false keeps a page's own Save buttons"
  attr :discard, :string, default: nil, doc: "an event pushed on Discard, to re-read the form"
  attr :target, :any, default: nil, doc: "the component `discard` goes to"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc """
  Unsaved changes: the sticky bar and the navigate-away confirmation.

      <Settings.unsaved_changes id="workspace-general" form="workspace-general-form"
        saved={@saved} discard="discard-general" target={@myself}>
        <.form id="workspace-general-form" ...>...</.form>
      </Settings.unsaved_changes>

  The `UnsavedChanges` hook (`assets/js/hooks/unsaved_changes.js`) owns the
  whole of the browser side, and it keeps one boolean: dirty or not. Input
  in a form inside makes it dirty, except inside `[data-unsaved-ignore]`
  (a typed confirmation, say); another hook can say so too, with an
  `unsaved:dirty` or `unsaved:clean` DOM event. A change to `saved`, or a
  form reset, makes it clean. No value is ever copied.

  While dirty, the bar shows "Unsaved changes · Discard / Save". Save
  submits `form` and says `save_label`. Discard resets the forms inside
  and pushes `discard`, so a form the server holds is drawn again from
  what is saved. `bar={false}` keeps only the confirmation, for a page
  whose sections still save separately.

  Leaving while dirty -- a patch or navigate link, any other link, or an
  element marked `data-leaves-page` -- asks first, in a dialog; closing
  or reloading the tab asks through `beforeunload`.
  """
  def unsaved_changes(assigns) do
    ~H"""
    <div
      id={@id}
      class={["unsaved-scope", @class]}
      phx-hook="UnsavedChanges"
      data-saved={@saved}
      data-discard-event={@discard}
      data-discard-target={@target}
    >
      {render_slot(@inner_block)}
      <div
        :if={@bar}
        id={"#{@id}-bar"}
        class="unsaved-bar"
        role="region"
        aria-label="Unsaved changes"
        data-unsaved-bar
        hidden
      >
        <span class="unsaved-label">Unsaved changes</span>
        <span class="unsaved-sep" aria-hidden="true">·</span>
        <span class="spacer"></span>
        <button type="button" class="ghost" data-unsaved-discard>Discard</button>
        <button type="submit" class="primary" form={@form} data-unsaved-save>{@save_label}</button>
      </div>
      <div
        id={"#{@id}-leave"}
        class="scrim unsaved-leave"
        data-unsaved-leave
        hidden
        phx-update="ignore"
      >
        <div
          class="dialog"
          role="alertdialog"
          aria-modal="true"
          aria-labelledby={"#{@id}-leave-title"}
          aria-describedby={"#{@id}-leave-body"}
        >
          <div class="dialog-head">
            <h2 id={"#{@id}-leave-title"}>Leave without saving?</h2>
          </div>
          <div class="dialog-body">
            <p id={"#{@id}-leave-body"}>
              You have unsaved changes on this page. If you leave, they are discarded.
            </p>
          </div>
          <div class="dialog-foot">
            <button type="button" class="ghost" data-unsaved-stay>Keep editing</button>
            <button type="button" class="danger" data-unsaved-confirm>Discard and leave</button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
