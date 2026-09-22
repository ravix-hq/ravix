defmodule RavixWeb.Live.PlansPanel do
  @moduledoc "Project plan forms and explicit paid assignments in the workspace."
  use RavixWeb, :live_component
  alias Ravix.{Accounts, Plans}
  alias Ravix.Accounts.Access
  alias Ravix.Plans.Assignment
  alias Ravix.Tooling.Authorization

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         plans: [],
         detail: nil,
         draft: nil,
         error: nil,
         busy: false,
         loaded: nil,
         request_id: Ecto.UUID.generate()
       )}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    case Access.project_access(assigns.current_user, assigns.project.id) do
      {:ok, _} ->
        key = {assigns.project.id, assigns.plan_id}

        {:ok,
         if(socket.assigns.loaded == key,
           do: socket,
           else: load(assign(socket, loaded: key, draft: nil, detail: nil))
         )}

      _ ->
        {:ok,
         assign(socket,
           plans: [],
           detail: nil,
           draft: nil,
           error: "This project is no longer available."
         )}
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    case Access.project_access(socket.assigns.current_user, socket.assigns.project.id) do
      {:ok, _} ->
        event(event, params, socket)

      _ ->
        {:noreply,
         assign(socket,
           detail: nil,
           plans: [],
           draft: nil,
           error: "This project is no longer available."
         )}
    end
  end

  defp event("new-plan", _, socket),
    do:
      {:noreply,
       assign(socket,
         detail: nil,
         draft: %{"title" => "", "summary" => "", "items" => [blank_item()]},
         error: nil
       )}

  defp event("cancel-edit", _, socket), do: {:noreply, assign(socket, draft: nil, error: nil)}

  defp event("edit-plan", _, socket) do
    detail = socket.assigns.detail

    items =
      Enum.map(detail.items, fn item ->
        Map.new(Map.take(item, [:id, :title, :brief, :acceptance, :dependencies]), fn {k, v} ->
          {to_string(k), v}
        end)
      end)

    {:noreply,
     assign(socket,
       draft: %{"title" => detail.plan.title, "summary" => detail.plan.summary, "items" => items}
     )}
  end

  defp event("edit-draft", %{"plan" => params}, socket),
    do: {:noreply, assign(socket, draft: draft(socket.assigns.draft, params))}

  defp event("add-item", _, socket),
    do:
      {:noreply,
       update(socket, :draft, &Map.update!(&1, "items", fn items -> items ++ [blank_item()] end))}

  defp event("remove-item", %{"id" => id}, socket),
    do:
      {:noreply,
       update(
         socket,
         :draft,
         &Map.update!(&1, "items", fn items -> Enum.reject(items, fn i -> i["id"] == id end) end)
       )}

  defp event("move-item", %{"id" => id, "direction" => direction}, socket) do
    items = socket.assigns.draft["items"]
    index = Enum.find_index(items, &(&1["id"] == id))
    target = if direction == "up", do: index - 1, else: index + 1

    items =
      if target in 0..(length(items) - 1),
        do:
          items
          |> List.replace_at(index, Enum.at(items, target))
          |> List.replace_at(target, Enum.at(items, index)),
        else: items

    {:noreply, assign(socket, draft: Map.put(socket.assigns.draft, "items", items))}
  end

  defp event("save-plan", %{"plan" => params}, socket) do
    attrs = draft(socket.assigns.draft, params)

    result =
      if socket.assigns.detail do
        plan = socket.assigns.detail.plan
        Plans.update(socket.assigns.current_user, plan.id, plan.version, attrs)
      else
        Plans.create(socket.assigns.current_user, socket.assigns.project.id, attrs)
      end

    case result do
      {:ok, plan} ->
        send(self(), {:plan_saved, plan.project_id, plan.id})
        {:noreply, assign(socket, draft: nil, error: nil, loaded: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, draft: attrs, error: message(reason))}
    end
  end

  defp event("archive-plan", _, socket) do
    plan = socket.assigns.detail.plan

    case Plans.update(socket.assigns.current_user, plan.id, plan.version, %{
           "archived" => !plan.archived
         }) do
      {:ok, _} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  defp event("refresh-plans", _, socket), do: {:noreply, load(socket)}

  defp event("note-item", %{"item_id" => id, "body" => body}, socket) do
    case Plans.note(socket.assigns.current_user, id, body) do
      {:ok, _} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  defp event("assign-items", params, socket) do
    assignments =
      Enum.map(Map.get(params, "selected", []), fn id ->
        case get_in(params, ["targets", id]) do
          value when is_binary(value) and value != "" -> %{"item_id" => id, "track_id" => value}
          _ -> %{"item_id" => id}
        end
      end)

    user = socket.assigns.current_user
    principal = Authorization.browser(user, socket.assigns.session_hash)
    plan_id = socket.assigns.detail.plan.id
    request_id = socket.assigns.request_id

    {:noreply,
     socket
     |> assign(busy: true, error: nil)
     |> start_async(:assign, fn ->
       Assignment.assign(user, principal, plan_id, assignments, request_id)
     end)}
  end

  @impl true
  def handle_async(name, result, socket) do
    with {:ok, _, _} <- Accounts.open_session(socket.assigns.session_hash),
         {:ok, _} <- Access.project_access(socket.assigns.current_user, socket.assigns.project.id) do
      settled(name, result, socket)
    else
      _ ->
        {:noreply,
         assign(socket,
           detail: nil,
           draft: nil,
           plans: [],
           busy: false,
           error: "Your access has ended."
         )}
    end
  end

  defp settled(:detail, {:ok, {:ok, detail}}, socket),
    do: {:noreply, assign(socket, detail: detail, busy: false)}

  defp settled(:assign, {:ok, {:ok, result}}, socket) do
    incomplete =
      Enum.any?(
        result[:items] || result["items"],
        &(Map.has_key?(&1, :error) || Map.has_key?(&1, "error"))
      )

    error =
      if incomplete,
        do: "Some assignments are unconfirmed. Inspect their tracks before starting more work."

    {:noreply,
     socket |> assign(error: error, busy: false, request_id: Ecto.UUID.generate()) |> load()}
  end

  # A refused assignment claimed its request ID without a result, so the same
  # ID would only ever answer "unconfirmed" again. Items that did get
  # reserved stay reserved, which is what stops a fresh ID provisioning twice.
  defp settled(:assign, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket, busy: false, error: message(reason), request_id: Ecto.UUID.generate())}

  defp settled(_, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: false, error: message(reason))}

  defp settled(_, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         busy: false,
         error: "The operation could not finish. Refresh to inspect its result."
       )}

  defp load(socket) do
    user = socket.assigns.current_user

    case Plans.list(user, socket.assigns.project.id) do
      {:ok, plans} ->
        socket = assign(socket, plans: plans)

        load_detail(socket, user, socket.assigns.plan_id)

      {:error, reason} ->
        assign(socket, plans: [], detail: nil, error: message(reason))
    end
  end

  defp load_detail(socket, _, nil), do: socket

  defp load_detail(socket, user, id) do
    project_id = socket.assigns.project.id

    socket
    |> assign(busy: true)
    |> start_async(:detail, fn ->
      case Plans.get(user, id) do
        {:ok, %{plan: %{project_id: ^project_id}}} = result -> result
        _ -> {:error, :not_found}
      end
    end)
  end

  defp draft(current, params) do
    rows = Map.get(params, "items", %{})

    items =
      Enum.map(current["items"], fn item ->
        attrs = Map.get(rows, item["id"], %{})

        attrs =
          if Map.has_key?(attrs, "dependencies"),
            do: Map.update!(attrs, "dependencies", &nonempty_dependencies/1),
            else: attrs

        Map.merge(item, Map.take(attrs, ~w(title brief acceptance dependencies)))
      end)

    Map.merge(current, Map.take(params, ~w(title summary))) |> Map.put("items", items)
  end

  defp nonempty_dependencies(ids), do: Enum.reject(ids, &(&1 == ""))

  defp blank_item,
    do: %{
      "id" => Ecto.UUID.generate(),
      "title" => "",
      "brief" => "",
      "acceptance" => "",
      "dependencies" => []
    }

  defp message(reason), do: RavixWeb.Error.from(reason).message
  defp status_label(status), do: status |> to_string() |> String.replace("_", " ")
  defp dependency_title(items, id), do: (Enum.find(items, &(&1.id == id)) || %{title: id}).title
  defp md(text), do: RavixWeb.Markdown.render_safe(text)
end
