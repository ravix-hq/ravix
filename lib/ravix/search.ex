defmodule Ravix.Search do
  @moduledoc "Scoped, local full-text search across projects, tracks and selected conversation text."
  alias Ravix.Accounts.{Access, User}
  alias Ravix.Search.{Query, Store}

  @type page :: %{results: [map()], page: pos_integer(), has_more: boolean()}
  @type reason :: {:unprocessable, String.t(), String.t()} | {:unavailable, String.t()}

  @doc "All query words must match, case-insensitively; punctuation is data, never SQL."
  @spec run(User.t(), map() | Query.t()) :: {:ok, page()} | {:error, reason()}
  def run(%User{} = user, params) do
    with {:ok, opts} <- Query.from(params) do
      safely(fn ->
        project_ids = Access.project_ids(user)
        rows = Store.search(user.id, project_ids, opts)
        {:ok, %{results: Enum.take(rows, 20), page: opts.page, has_more: length(rows) > 20}}
      end)
    end
  end

  @doc "Bounded filter choices, drawn only from projects/tracks this user may see."
  @spec filters(User.t(), map() | Query.t()) :: {:ok, map()} | {:error, reason()}
  def filters(%User{} = user, params) do
    with {:ok, opts} <- Query.from(params) do
      safely(fn -> {:ok, Store.filters(user.id, Access.project_ids(user), opts.project)} end)
    end
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

  defp safely(fun) do
    fun.()
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:unavailable, "Search is temporarily unavailable. Try again."}}
  end
end
