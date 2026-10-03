defmodule RavixWeb.SearchLive do
  @moduledoc "Authenticated global search; async pages are checked again before display."
  use RavixWeb, :live_view
  alias Ravix.{Hub, Search}
  alias Ravix.Accounts.User
  alias RavixWeb.Live.Guard

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_access, Guard.ttl_ms())

    {:ok,
     assign(socket,
       page_title: "Search · Ravix",
       params: %{},
       results: [],
       filters: %{projects: [], tracks: []},
       page: 1,
       has_more: false,
       loading: false,
       error: nil,
       subscriptions: MapSet.new()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case Guard.verify(nil, socket.assigns.session_hash) do
      {:ok, guard} -> {:noreply, socket |> assign(session_guard: guard) |> load(params)}
      :error -> {:noreply, redirect(socket, to: "/login")}
    end
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    {:noreply, push_patch(socket, to: path(Map.delete(params, "page")))}
  end

  @impl true
  def handle_async(:search, {:ok, {:ok, page}}, socket) do
    with {:ok, page} <- Search.revalidate(socket.assigns.current_user, page),
         {:ok, filters} <- Search.filters(socket.assigns.current_user, socket.assigns.params) do
      {:noreply,
       socket
       |> subscriptions(filters)
       |> assign(
         filters: filters,
         results: page.results,
         page: page.page,
         has_more: page.has_more,
         loading: false
       )}
    else
      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  def handle_async(:search, {:ok, {:error, reason}}, socket),
    do: {:noreply, failed(socket, reason)}

  def handle_async(:search, {:exit, _reason}, socket),
    do:
      {:noreply, failed(socket, {:unavailable, "Search is temporarily unavailable. Try again."})}

  @impl true
  def handle_info(:refresh_access, socket) do
    Process.send_after(self(), :refresh_access, Guard.ttl_ms())
    {:noreply, load(socket, socket.assigns.params)}
  end

  def handle_info({:hub, %Hub.Event{name: name}}, socket) when name in [:people, :tracks, :reply],
    do: {:noreply, load(socket, socket.assigns.params)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(%{assigns: %{current_user: %User{} = user}} = socket, params) do
    socket
    |> cancel_async(:search)
    |> assign(
      params: params,
      results: [],
      filters: %{projects: [], tracks: []},
      loading: true,
      error: nil,
      has_more: false
    )
    |> start_async(:search, fn -> Search.run(user, params) end)
  end

  defp load(socket, _params), do: redirect(socket, to: "/login")

  defp failed(socket, reason),
    do:
      assign(socket,
        loading: false,
        results: [],
        has_more: false,
        error: RavixWeb.Error.from(reason).message
      )

  defp subscriptions(socket, filters) do
    wanted = MapSet.new(filters.projects, & &1.id)

    if connected?(socket) do
      Enum.each(MapSet.difference(wanted, socket.assigns.subscriptions), &Hub.subscribe/1)
      Enum.each(MapSet.difference(socket.assigns.subscriptions, wanted), &Hub.unsubscribe/1)
    end

    assign(socket, subscriptions: wanted)
  end

  defp path(params),
    do: "/search?" <> URI.encode_query(Map.take(params, ~w(q project track page)))

  defp page_path(params, page), do: path(Map.put(params, "page", to_string(page)))
  defp result_path(%{kind: "project"} = row), do: "/p/#{row.project_id}"

  defp result_path(row) do
    base = "/p/#{row.project_id}/t/#{row.track_id}"

    if row.thread_id,
      do: base <> "?" <> URI.encode_query(%{"thread" => row.thread_id}),
      else: base
  end

  defp kind_label("queued_prompt"), do: "Pending prompt"
  defp kind_label("prompt"), do: "Human prompt"
  defp kind_label("assistant"), do: "Assistant reply"
  defp kind_label("project"), do: "Project"
  defp kind_label("track"), do: "Track"
end
