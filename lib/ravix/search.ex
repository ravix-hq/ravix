defmodule Ravix.Search do
  @moduledoc "Scoped, local full-text search across projects, tracks and selected conversation text."
  alias Ravix.Accounts.{Access, User}
  alias Ravix.Search.Store

  @type page :: %{results: [map()], page: pos_integer(), has_more: boolean()}
  @type reason :: {:unprocessable, String.t(), String.t()} | {:unavailable, String.t()}

  @doc "All query words must match, case-insensitively; punctuation is data, never SQL."
  @spec run(User.t(), map()) :: {:ok, page()} | {:error, reason()}
  def run(%User{} = user, params) do
    with {:ok, opts} <- options(params) do
      safely(fn ->
        project_ids = Access.project_ids(user)
        rows = Store.search(user.id, project_ids, opts)
        {:ok, %{results: Enum.take(rows, 20), page: opts.page, has_more: length(rows) > 20}}
      end)
    end
  end

  @doc "Bounded filter choices, drawn only from projects/tracks this user may see."
  @spec filters(User.t(), map()) :: {:ok, map()} | {:error, reason()}
  def filters(%User{} = user, params) do
    safely(fn -> {:ok, Store.filters(user.id, Access.project_ids(user), params["project"])} end)
  end

  @doc "Recheck each async result against current membership before it reaches the browser."
  @spec revalidate(User.t(), page()) :: {:ok, page()} | {:error, reason()}
  def revalidate(%User{} = user, page) do
    safely(fn -> {:ok, revalidated(user, page)} end)
  end

  defp revalidated(user, page) do
    projects = MapSet.new(Access.project_ids(user))
    tracks = Store.visible_ids(user.id, Enum.map(page.results, & &1.track_id)) |> MapSet.new()

    results =
      Enum.filter(page.results, fn row ->
        if row.kind == "project",
          do: MapSet.member?(projects, row.project_id),
          else: MapSet.member?(tracks, row.track_id)
      end)

    %{
      page
      | results: results,
        has_more: page.has_more and length(results) == length(page.results)
    }
  end

  defp options(params) do
    query = params["q"] || ""
    page = params["page"] || "1"

    with true <-
           is_binary(query) and String.valid?(query) and byte_size(query) <= 500 and
             not String.contains?(query, <<0>>),
         {page, ""} when page in 1..1000 <- parse_page(page) do
      {:ok,
       %{
         query: String.trim(query),
         page: page,
         project: filter(params["project"]),
         track: filter(params["track"])
       }}
    else
      _ ->
        {:error,
         {:unprocessable, "invalid_search",
          "Use a query up to 500 bytes and a page from 1 to 1000."}}
    end
  end

  defp parse_page(page) when is_binary(page), do: Integer.parse(page)
  defp parse_page(_), do: :error
  defp filter(value) when is_binary(value) and byte_size(value) in 1..200, do: value
  defp filter(_), do: nil

  defp safely(fun) do
    fun.()
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:unavailable, "Search is temporarily unavailable. Try again."}}
  end
end
