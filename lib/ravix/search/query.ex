defmodule Ravix.Search.Query do
  @moduledoc "One validated search request for querying and rendering. No row access."
  defstruct query: "", page: 1, project: nil, track: nil

  @type t :: %__MODULE__{
          query: String.t(),
          page: pos_integer(),
          project: String.t() | nil,
          track: String.t() | nil
        }

  @doc "Validate URL/form values once; an already validated request passes unchanged."
  def from(%__MODULE__{} = query), do: {:ok, query}

  def from(params) when is_map(params) do
    with {:ok, query} <- text(params["q"], 500),
         {:ok, project} <- text(params["project"], 200),
         {:ok, track} <- text(params["track"], 200),
         {page, ""} when page in 1..1000 <- parse_page(params["page"] || "1") do
      {:ok,
       %__MODULE__{query: String.trim(query || ""), page: page, project: project, track: track}}
    else
      _ ->
        {:error,
         {:unprocessable, "invalid_search",
          "Use text for search and filters, a query up to 500 bytes, and a page from 1 to 1000."}}
    end
  end

  @doc "Safe form values, including when a forged URL was refused."
  def form_params(%__MODULE__{} = query),
    do: %{
      "q" => query.query,
      "project" => query.project || "",
      "track" => query.track || "",
      "page" => to_string(query.page)
    }

  def form_params(params),
    do: Map.new(~w(q project track), &{&1, form_text(params[&1], form_limit(&1))})

  defp form_text(value, limit) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: String.slice(value, 0, limit),
      else: ""
  end

  defp form_text(_value, _limit), do: ""
  defp form_limit("q"), do: 500
  defp form_limit(_filter), do: 200

  defp text(value, _limit) when value in [nil, ""], do: {:ok, nil}

  defp text(value, limit) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= limit and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: :error
  end

  defp text(_value, _limit), do: :error
  defp parse_page(value) when is_binary(value), do: Integer.parse(value)
  defp parse_page(_value), do: :error
end
