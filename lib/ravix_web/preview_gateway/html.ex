defmodule RavixWeb.PreviewGateway.Html do
  @moduledoc """
  Insert the activity script once into HTML without buffering the response.

  The gateway holds back bytes only until it has seen `</head>`, then emits
  everything and passes the rest straight through. A page with no head (or
  one that has not shown it in the first 32 KiB) gets the script at that
  point instead, and a response that ends first gets it at the end. The
  search is case-insensitive over raw bytes, so a tag split across two chunks
  is still found and non-UTF-8 pages are not decoded.

  A reducer rather than a stream: the proxy threads it through `chunk/2`.
  """

  @script ~s(<script src="/__ravix/activity.js" defer></script>)
  @limit 32_768

  @opaque t :: %__MODULE__{pending: binary(), injected: boolean()}
  defstruct pending: <<>>, injected: false

  @doc "A fresh transform, nothing injected yet."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Feed a chunk; returns what may be sent now and the transform to keep."
  @spec push(t(), binary()) :: {iodata(), t()}
  def push(%__MODULE__{injected: true} = html, chunk), do: {chunk, html}

  def push(%__MODULE__{pending: pending} = html, chunk),
    do: inject(%{html | pending: pending <> chunk}, false)

  @doc "The response ended: whatever is still held, with the script if it never fitted."
  @spec flush(t()) :: iodata()
  def flush(%__MODULE__{injected: true}), do: []
  def flush(html), do: html |> inject(true) |> elem(0)

  defp inject(%__MODULE__{pending: pending} = html, final?) do
    index =
      case Regex.run(~r{</head>}i, pending, return: :index) do
        [{index, _}] -> index
        nil -> nil
      end

    if index || final? || byte_size(pending) > @limit do
      index = index || byte_size(pending)
      <<before::binary-size(index), rest::binary>> = pending
      {[before, @script, rest], %{html | pending: <<>>, injected: true}}
    else
      {[], html}
    end
  end
end
