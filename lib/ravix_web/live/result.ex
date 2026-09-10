defmodule RavixWeb.Live.Result do
  @moduledoc """
  A context's answer, applied to a socket.

  Every context function returns `:ok`, `{:ok, value}` or `{:error, reason}`,
  and every LiveView does the same three things with them: run the success
  branch, or turn the reason into the one sentence `RavixWeb.Error` has for
  it and flash that. Both pages had written this out privately, which meant
  the shape of a refusal was a per-page decision rather than the boundary's,
  and a third page would have made it a third.

  Imported into every LiveView by `RavixWeb.live_view/0`.
  """

  alias RavixWeb.Error

  @doc """
  Apply `response` to `socket`.

  `fun` is called with the socket and the value on success, `nil` for a bare
  `:ok`. A failure never reaches it: the reason becomes a flash and the
  socket is otherwise untouched, so a page that could not do the thing still
  shows what it showed before rather than a half-updated version of it.
  """
  @spec result(Phoenix.LiveView.Socket.t(), :ok | {:ok, term()} | {:error, term()}, function()) ::
          Phoenix.LiveView.Socket.t()
  def result(socket, :ok, fun), do: fun.(socket, nil)
  def result(socket, {:ok, value}, fun), do: fun.(socket, value)
  def result(socket, {:error, reason}, _fun), do: error(socket, reason)

  @doc "Flash the sentence `RavixWeb.Error` has for `reason`."
  @spec error(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def error(socket, reason),
    do: Phoenix.LiveView.put_flash(socket, :error, Error.from(reason).message)
end
