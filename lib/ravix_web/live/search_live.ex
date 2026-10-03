defmodule RavixWeb.SearchLive do
  @moduledoc "Authenticated global search; async pages are checked again before display."
  use RavixWeb, :live_view
  alias Ravix.Accounts.User
  alias Ravix.{Hub, Search}
  alias Ravix.Search.Query
  alias RavixWeb.Live.Guard

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_access, Guard.ttl_ms())

    {:ok,
     assign(socket,
       page_title: "Search · Ravix",
       params: %{},
       draft_params: %{},
       results: [],
       filters: %{projects: [], tracks: []},
       query: nil,
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

  def handle_event("draft-search", %{"search" => params}, socket) do
    draft = Query.form_params(params)

    draft =
      if draft["project"] != socket.assigns.draft_params["project"],
        do: Map.put(draft, "track", ""),
        else: draft

    {:noreply, socket |> assign(draft_params: draft) |> refresh()}
  end

  @impl true
  def handle_async(:search, {:ok, {:ok, page}}, socket),
    do: {:noreply, apply_page(socket, page)}

  def handle_async(:search, {:ok, {:error, reason}}, socket),
    do: {:noreply, failed(socket, reason)}

  def handle_async(:search, {:exit, _reason}, socket),
    do:
      {:noreply, failed(socket, {:unavailable, "Search is temporarily unavailable. Try again."})}

  @impl true
  def handle_info(:refresh_access, socket) do
    Process.send_after(self(), :refresh_access, Guard.ttl_ms())
    {:noreply, refresh(socket)}
  end

  def handle_info({:hub, %Hub.Event{name: name}}, socket)
      when name in [:people, :tracks, :reply] do
    socket = refresh(socket)

    case socket.assigns.query do
      %Query{} = query ->
        user = socket.assigns.current_user

        {:noreply,
         socket
         |> cancel_async(:search)
         |> assign(loading: true)
         |> start_async(:search, fn -> Search.run(user, query) end)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(%{assigns: %{current_user: %User{} = user}} = socket, params) do
    socket = cancel_async(socket, :search)

    case Query.from(params) do
      {:ok, query} ->
        socket
        |> assign(
          params: Query.form_params(query),
          draft_params: Query.form_params(query),
          query: query,
          results: [],
          filters: %{projects: [], tracks: []},
          loading: true,
          error: nil,
          has_more: false
        )
        |> start_async(:search, fn -> Search.run(user, query) end)

      {:error, reason} ->
        socket
        |> assign(
          params: Query.form_params(params),
          draft_params: Query.form_params(params),
          filters: %{projects: [], tracks: []}
        )
        |> failed(reason)
    end
  end

  defp load(socket, _params), do: redirect(socket, to: "/login")

  defp refresh(%{assigns: %{query: nil}} = socket), do: socket

  defp refresh(socket) do
    refreshed =
      apply_page(socket, %{
        results: socket.assigns.results,
        page: socket.assigns.page,
        has_more: socket.assigns.has_more
      })

    if refreshed.assigns.query,
      do: assign(refreshed, loading: socket.assigns.loading),
      else: refreshed
  end

  defp apply_page(socket, page) do
    with {:ok, page} <- Search.revalidate(socket.assigns.current_user, page),
         {:ok, filters} <-
           Search.filters(socket.assigns.current_user, socket.assigns.draft_params) do
      socket
      |> subscriptions(filters, page.results)
      |> assign(
        filters: filters,
        results: page.results,
        page: page.page,
        has_more: page.has_more,
        loading: false
      )
    else
      {:error, reason} -> failed(socket, reason)
    end
  end

  defp failed(socket, reason) do
    socket
    |> cancel_async(:search)
    |> subscriptions(%{projects: [], tracks: []}, [])
    |> assign(
      loading: false,
      results: [],
      filters: %{projects: [], tracks: []},
      query: nil,
      has_more: false,
      error: RavixWeb.Error.from(reason).message
    )
  end

  defp subscriptions(socket, filters, results) do
    wanted = MapSet.new(Enum.map(filters.projects, & &1.id) ++ Enum.map(results, & &1.project_id))

    if connected?(socket) do
      Enum.each(MapSet.difference(wanted, socket.assigns.subscriptions), &Hub.subscribe/1)
      Enum.each(MapSet.difference(socket.assigns.subscriptions, wanted), &Hub.unsubscribe/1)
    end

    assign(socket, subscriptions: wanted)
  end

  defp path(params),
    do:
      "/search?" <>
        URI.encode_query(
          Map.take(params, ~w(q project track page))
          |> Enum.filter(fn {_key, value} -> is_binary(value) and value != "" end)
        )

  defp query_text(params) do
    case params["q"] do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

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
