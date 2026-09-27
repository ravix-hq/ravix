defmodule Ravix.QueueStreamTransport do
  @moduledoc "Queue tests keep a quiet provider stream open and can inject actual SSE frames."
  alias Ravix.Fountain.FakeTransport

  defdelegate request(method, url, headers, body, timeout), to: FakeTransport

  def stream(_method, url, _headers, _timeout, on_chunk) do
    uri = URI.parse(url)
    _registered = :global.register_name({__MODULE__, uri.host, uri.path}, self())
    loop(on_chunk)
  end

  def whereis(client, conversation) do
    :global.whereis_name(
      {__MODULE__, URI.parse(client.base_url).host, "/api/conversations/#{conversation}/stream"}
    )
  end

  defp loop(on_chunk) do
    receive do
      {:emit, event} ->
        on_chunk.(FakeTransport.frame(event["id"], "stage", event))
        loop(on_chunk)

      :finish ->
        {:ok, 200, [], nil}
    end
  end
end
