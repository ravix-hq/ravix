defmodule RavixWeb.Live.QuickStart do
  @moduledoc """
  A first request and where to run it: "What do you want to work on?", a
  repository, and Start.

  The walkthrough's last step, `/home` for somebody with no work yet, and a
  project page with no tracks all draw this one form. Submitting opens a
  track with the prompt queued on its first thread, which is exactly what
  the New track dialog does with a prompt typed into it (RAV-47): the same
  `open_track/4`, the same queue, the same "waits until setup is ready". A
  target that is a repository, or scratch, is a project first, created by
  `Ravix.Projects.create/2` as the New project dialog creates one, so its
  name, its agent check and its Fountain names are that function's.

  ## What the page keeps

  The page holds the form (`quick_form`), whether a start is in flight
  (`quick_busy`) and what may be chosen (`targets/1`). It routes the three
  `quick-start-*` events here and runs `run/4` in its own task, because the
  page is what knows where to go afterwards: the walkthrough navigates and
  finishes itself, the workspace reads its rail first so the patch lands on
  a project it lists.

  ## A target

  A string the form round-trips: `"project:<id>"`, `"repo:<owner/name>"` or
  `"scratch"`. Only a value `targets/1` offered is ever acted on --- the
  same rule `RavixWeb.Live.NewProject.create/3` keeps for its repository
  field --- and a project id is only a lookup key: `Ravix.Tracks.open/3`
  asks the person's access to it again.

  This is deliberately small. RAV-60 is rebuilding the New track dialog into
  a prompt-first composer, and once that lands this form should become that
  composer with a target picker; the events and `run/4` are the seam.
  """
  use RavixWeb, :html

  alias Ravix.{Projects, Tracks}
  alias Ravix.Accounts.User
  alias RavixWeb.Live.{Async, Form}

  @suggestions [
    "Explain how this codebase is organized",
    "Run the app and open a preview",
    "Find and fix one small bug"
  ]

  @doc "The suggested first prompts, in the order they are offered."
  @spec suggestions() :: [String.t()]
  def suggestions, do: @suggestions

  @doc "A fresh form, preselecting `target` when there is an obvious one."
  @spec init(Phoenix.LiveView.Socket.t(), String.t() | nil) :: Phoenix.LiveView.Socket.t()
  def init(socket, target \\ nil) do
    runtime = socket.assigns.current_user && socket.assigns.current_user.agent

    assign(socket,
      quick_form:
        Form.new(:quick_start, %{
          "target" => target || "",
          "prompt" => "",
          "runtime" => runtime && to_string(runtime)
        }),
      quick_busy: false
    )
  end

  @doc """
  What may be chosen, as `{label, value}` pairs in groups: the repositories
  GitHub shows (what `Ravix.Projects.repos/2` answered), then scratch. A
  project page offers only itself, as `"project:<id>"`, and draws no picker.
  """
  @spec targets([map()]) :: [{String.t(), [{String.t(), String.t()}]}]
  def targets(repos) do
    [
      {"GitHub repositories", for(r <- repos, do: {r.full_name, "repo:" <> r.full_name})},
      {"Other", [{"No repository (scratch machine)", "scratch"}]}
    ]
    |> Enum.reject(fn {_group, options} -> options == [] end)
  end

  @doc """
  The one target worth preselecting: the only repository GitHub shows, or
  scratch when it shows none. Nothing when there is a real choice to make.
  """
  @spec preselect([{String.t(), [{String.t(), String.t()}]}]) :: String.t() | nil
  def preselect(groups) do
    case Enum.flat_map(groups, fn {_group, options} -> options end) do
      [{_, "scratch"}] -> "scratch"
      [{_, value}, {_, "scratch"}] -> value
      _ -> nil
    end
  end

  @doc "Keep what was typed."
  def edit(socket, params) when is_map(params) do
    params = Map.take(params, ["target", "prompt", "runtime"])

    assign(socket,
      quick_form: Form.new(:quick_start, Map.merge(socket.assigns.quick_form.params, params))
    )
  end

  @doc "Fill the prompt with a suggestion. Only the suggestions offered fill it."
  def suggest(socket, prompt) when prompt in @suggestions, do: edit(socket, %{"prompt" => prompt})
  def suggest(socket, _prompt), do: socket

  @doc """
  Check what was submitted and, when it is something to start, run `start`
  in a task named `:quick_start`.

  `start` receives the parsed target --- `{:project, id}`,
  `{:repo, repo}` (one of `repos`), or `:scratch` --- the prompt and the
  runtime, and is where the page wraps `run/4` with what it needs back.
  """
  def submit(%{assigns: %{quick_busy: true}} = socket, _params, _groups, _repos, _start),
    do: socket

  def submit(socket, params, groups, repos, start) do
    socket = edit(socket, params)
    params = socket.assigns.quick_form.params
    prompt = params["prompt"] || ""

    with {:ok, target} <- target(params["target"], groups, repos),
         :ok <- present(prompt) do
      runtime = runtime(params["runtime"])

      socket
      |> assign(quick_busy: true)
      |> Async.traced_async(:quick_start, fn -> start.(target, prompt, runtime) end)
    else
      {:error, reason} ->
        {:ok, form} = Form.refuse(socket.assigns.quick_form, reason)
        assign(socket, quick_form: form)
    end
  end

  defp target(value, groups, repos) do
    offered = for {_group, options} <- groups, {_label, v} <- options, do: v

    cond do
      value in [nil, ""] ->
        {:error, {:unprocessable, "no_target", "Choose a repository, or No repository."}}

      value not in offered ->
        {:error,
         {:unprocessable, "invalid_repository", "Choose a repository from the list, or scratch."}}

      value == "scratch" ->
        {:ok, :scratch}

      String.starts_with?(value, "project:") ->
        {:ok, {:project, String.replace_prefix(value, "project:", "")}}

      true ->
        name = String.replace_prefix(value, "repo:", "")

        case Enum.find(repos, &(&1.full_name == name)) do
          nil -> {:error, {:unprocessable, "invalid_repository", "That repository has gone."}}
          repo -> {:ok, {:repo, repo}}
        end
    end
  end

  defp present(prompt) do
    if String.trim(prompt) == "",
      do: {:error, {:unprocessable, "empty_prompt", "Say what you want to work on."}},
      else: :ok
  end

  defp runtime(value) when value in ["claude", "codex"], do: value
  defp runtime(_value), do: nil

  @doc """
  Start: the project when the target is not one yet, then a track on it
  with `prompt` as its first message.

  Answers `{:ok, %{project: project, track: track, queued: queued}}` once
  the track is open. A project created whose track then could not open is
  still `{:ok, ...}`, with `track: nil` and the refusal in `error`, so the
  page can go to the project that now exists and say what went wrong rather
  than offer to create it a second time.
  """
  @spec run(
          User.t(),
          {:project, String.t()} | {:repo, map()} | :scratch,
          String.t(),
          String.t() | nil
        ) ::
          {:ok, map()} | {:error, term()}
  def run(%User{} = user, {:project, id}, prompt, _runtime) do
    with {:ok, {track, queued}} <- open_track(user, id, blank_track(), prompt),
         do: {:ok, %{project: %{id: id}, track: track, queued: queued}}
  end

  def run(%User{} = user, target, prompt, runtime) do
    with {:ok, project} <- Projects.create(user, project_attrs(target, prompt, runtime)) do
      case open_track(user, project.id, blank_track(), prompt) do
        {:ok, {track, queued}} -> {:ok, %{project: project, track: track, queued: queued}}
        {:error, reason} -> {:ok, %{project: project, track: nil, error: reason}}
      end
    end
  end

  defp project_attrs({:repo, repo}, _prompt, runtime),
    do: %{
      "name" => "",
      "repo" => repo.full_name,
      "installation_id" => repo.installation_id,
      "runtime" => runtime
    }

  defp project_attrs(:scratch, prompt, runtime),
    do: %{"name" => scratch_name(prompt), "runtime" => runtime}

  # A scratch machine has no repository to be named after, so it is named
  # after what it is for: the prompt's first few words.
  defp scratch_name(prompt) do
    prompt
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(5)
    |> Enum.join(" ")
    |> String.slice(0, 60)
  end

  defp blank_track, do: %{title: "", visibility: "project", origin: %{kind: "blank"}}

  @doc """
  A track, and `prompt` as its first message.

  The prompt goes through the same queue as one sent from the composer, on
  the default thread, and waits there until setup is ready. The track is
  already open by then, so a refused prompt does not undo it: the answer is
  `{:ok, {track, {:error, reason}}}` and the page opens the track and says
  the prompt was not queued. An empty prompt queues nothing (`:none`).
  """
  @spec open_track(User.t(), String.t(), map(), String.t()) ::
          {:ok, {map(), :none | {:ok, term()} | {:error, term()}}} | {:error, term()}
  def open_track(%User{} = user, project_id, attrs, prompt) do
    with {:ok, track} <- Tracks.open(user, project_id, attrs) do
      if String.trim(prompt) == "",
        do: {:ok, {track, :none}},
        else:
          {:ok,
           {track,
            Tracks.prompt(user, track.id, %{prompt: prompt, request_id: Ecto.UUID.generate()})}}
    end
  end

  @doc "The sentence for a first prompt the track opened without."
  @spec refused(:none | {:ok, term()} | {:error, term()}) :: String.t() | nil
  def refused({:error, reason}),
    do:
      "The track opened, but its first prompt was not queued. #{RavixWeb.Error.from(reason).message}"

  def refused(_queued), do: nil

  # ── drawing ──────────────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :busy, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :loading, :boolean, default: false, doc: "whether the repositories are still loading"
  attr :groups, :list, default: [], doc: "`targets/2`; ignored when `project` is given"
  attr :project, :any, default: nil, doc: "a fixed target: the project page's own"
  attr :agent, :boolean, default: true, doc: "whether to offer the agent for a new project"
  attr :label, :string, default: "What do you want to work on?"
  attr :submit, :string, default: "Start"
  attr :submit_class, :string, default: "primary"
  attr :class, :string, default: nil
  slot :notice

  def composer(assigns) do
    assigns = assign(assigns, label: label(assigns))

    ~H"""
    <div class={["quick-start", @class]} id={@id}>
      <.form
        :let={f}
        for={@form}
        id={"#{@id}-form"}
        phx-change="quick-start-edit"
        phx-submit="quick-start"
      >
        <input :if={@project} type="hidden" name={f[:target].name} value={"project:" <> @project.id} />
        <div :if={!@project} class="quick-start-target">
          <.input
            field={f[:target]}
            id={"#{@id}-target"}
            type="select"
            label="Repository"
            prompt={if f[:target].value in [nil, ""], do: "Choose a repository…"}
            options={Enum.map(@groups, fn {group, options} -> {group, options} end)}
            disabled={@busy}
          />
          <.loading_status :if={@loading}>Loading GitHub repositories…</.loading_status>
        </div>
        <.input
          field={f[:prompt]}
          id={"#{@id}-prompt"}
          type="textarea"
          label={@label}
          rows="3"
          placeholder="Describe a change, a question, or a bug to chase"
          disabled={@busy}
        />
        <div class="quick-start-suggestions" role="group" aria-label="Suggested first prompts">
          <button
            :for={suggestion <- suggestions()}
            type="button"
            class="chip quick-start-suggestion"
            phx-click="quick-start-suggest"
            phx-value-prompt={suggestion}
            disabled={@busy}
          >
            {suggestion}
          </button>
        </div>
        {render_slot(@notice)}
        <div class="quick-start-actions">
          <label
            :if={!@project && @agent}
            class="quick-start-agent chip"
            for={"#{@id}-runtime"}
            title="The agent a new project runs on"
          >
            <span class="sr-only">Agent</span>
            <select id={"#{@id}-runtime"} name={f[:runtime].name} disabled={@busy}>
              <option
                :for={{label, value} <- RavixWeb.AgentName.options()}
                value={value}
                selected={f[:runtime].value == value}
              >
                {label}
              </option>
            </select>
          </label>
          <p :for={{message, _} <- f[:runtime].errors} class="error">{message}</p>
          <span class="spacer"></span>
          <.loading_status :if={@busy}>Starting…</.loading_status>
          <button
            type="submit"
            class={[@submit_class, "quick-start-submit"]}
            id={"#{@id}-submit"}
            disabled={@busy or @disabled}
          >
            {@submit}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  # The question names where the answer goes, once that is decided.
  defp label(%{project: %{} = project}),
    do: "What do you want to work on in #{project.repo || project.name}?"

  defp label(%{form: form, groups: groups, label: label}) do
    chosen = form[:target].value

    case for({_group, options} <- groups, {name, ^chosen} <- options, do: name) do
      [name | _] when chosen != "scratch" -> "What do you want to work on in #{name}?"
      _ -> label
    end
  end

  @doc "Three sentences on the words the rest of the app uses, and where to read more."
  attr :id, :string, required: true

  def explainer(assigns) do
    ~H"""
    <ul class="quick-start-explainer" id={@id} aria-label="What happens next">
      <li>
        <strong>A track</strong>
        is one piece of work: its own branch, machine and conversation with your agent.
      </li>
      <li>
        <strong>A preview</strong>
        is your app running on the track's machine, one click from the conversation.
      </li>
      <li>
        <strong>Sharing</strong>
        a track lets a teammate prompt the same agent, with everything said so far.
      </li>
      <li><.link navigate="/welcome?from=start">How it works</.link></li>
    </ul>
    """
  end
end
