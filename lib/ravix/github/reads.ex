defmodule Ravix.GitHub.Reads do
  @moduledoc """
  Short-lived display reads, shared by concurrent callers on this instance.

  The key includes the API host, App, credential scope, path and representation.
  User scopes are fingerprints, never bearer tokens. A value may be displayed
  for its TTL; its validators survive for an hour so the next read can ask
  GitHub whether it changed. A 304 reuses only that credential's representation.
  Errors never fall back to old data. Authorization-sensitive reads bypass this
  cache entirely (project creation verifies repository access afresh).
  """

  alias Ravix.{Clock, Memo, Trace}
  alias Ravix.GitHub.Error

  @name __MODULE__
  @retention_ms 3_600_000

  @doc "Read a representation, coalescing misses and revalidating expired display data."
  @spec fetch(tuple(), non_neg_integer(), (list() -> term()), (Req.Response.t() -> term())) ::
          {:ok, term()} | {:error, Error.t()}
  def fetch(key, ttl, load, decode) do
    now = Clock.now_ms()

    case Memo.peek(@name, key, now) do
      {:ok, {:error, _} = error} -> error
      _ -> fetch_value(key, ttl, now, load, decode)
    end
  end

  defp fetch_value(key, ttl, now, load, decode) do
    case Memo.peek(@name, key, now, now - ttl) do
      {:ok, _} -> Trace.annotate(%{"github.cache" => :hit})
      :miss -> Trace.annotate(%{"github.cache" => :miss})
    end

    result =
      Memo.fetch(@name, key, fn -> revalidate(key, load, decode) end, &expires/2,
        now_ms: now,
        newer_than: now - ttl,
        run: :caller,
        on_crash: fn _ -> {:error, %Error{message: "The GitHub read did not complete."}} end
      )

    case result do
      {:ok, entry} -> {:ok, entry.value}
      {:error, _} = error -> error
    end
  end

  defp revalidate(key, load, decode) do
    previous =
      case Memo.peek(@name, key) do
        {:ok, {:ok, entry}} -> entry
        _ -> nil
      end

    with {:ok, response} <- load.(validators(previous)) do
      representation(response, previous, decode)
    end
  end

  defp representation(%{status: 304}, nil, _decode),
    do:
      {:error,
       %Error{status: 304, message: "GitHub returned 304 without a cached representation."}}

  defp representation(%{status: 304}, previous, _decode), do: {:ok, previous}

  defp representation(response, _previous, decode) do
    with {:ok, value} <- decode.(response) do
      {:ok,
       %{
         value: value,
         etag: first_header(response, "etag"),
         modified: first_header(response, "last-modified")
       }}
    end
  end

  defp validators(%{etag: etag}) when is_binary(etag), do: [{"if-none-match", etag}]

  defp validators(%{modified: modified}) when is_binary(modified),
    do: [{"if-modified-since", modified}]

  defp validators(_), do: []

  defp first_header(response, name), do: response |> Req.Response.get_header(name) |> List.first()

  defp expires({:ok, _}, _started), do: Clock.now_ms() + @retention_ms
  defp expires({:error, %Error{status: status}}, _started) when status in [401, 403, 404], do: nil

  defp expires({:error, error}, _started),
    do: max(Clock.now_ms() + 60_000, error.retry_at_ms || 0)
end
