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

  alias Phoenix.LiveView.Socket
  alias RavixWeb.Error
  alias RavixWeb.Live.Form

  @typedoc "A context's answer, in the three shapes every one of them shares."
  @type response :: :ok | {:ok, term()} | {:error, term()}

  @typedoc """
  The success branch: the socket and the value, or `nil` for a bare `:ok`.

  Spelled out rather than left as `function()`, which said only "some
  function" -- not its arity, not that it answers with a socket. Every caller
  here passes a two-argument one and returns a socket; a `fn s -> s end`
  would have type-checked and then raised at the click that used it.
  """
  @type on_ok :: (Socket.t(), term() -> Socket.t())

  @doc """
  Apply `response` to `socket`.

  `fun` is called with the socket and the value on success, `nil` for a bare
  `:ok`. A failure never reaches it: the reason becomes a flash and the
  socket is otherwise untouched, so a page that could not do the thing still
  shows what it showed before rather than a half-updated version of it.
  """
  @spec result(Socket.t(), response(), on_ok()) :: Socket.t()
  def result(socket, :ok, fun), do: fun.(socket, nil)
  def result(socket, {:ok, value}, fun), do: fun.(socket, value)
  def result(socket, {:error, reason}, _fun), do: error(socket, reason)

  @doc """
  Apply `response`, putting a refusal on a form rather than in the flash.

  `form` names the assign holding a `RavixWeb.Live.Form`. A refusal that
  belongs to one of its fields lands there, beside the input it is about; a
  refusal that belongs to no field --- Fountain unreachable, the repository
  gone --- falls through to the flash, which is still the right place for
  it. Success is exactly `result/3`.
  """
  @spec result(Socket.t(), response(), on_ok(), atom()) :: Socket.t()
  def result(socket, {:error, reason} = response, fun, form) do
    case Form.refuse(socket.assigns[form], reason) do
      {:ok, refused} -> Phoenix.Component.assign(socket, form, refused)
      :error -> result(socket, response, fun)
    end
  end

  def result(socket, response, fun, _form), do: result(socket, response, fun)

  @doc """
  Flash the sentence `RavixWeb.Error` has for `reason`.

  A `live_component` cannot do this itself. `Phoenix.LiveView.put_flash/3`
  inside one changes a socket the page never renders, so the flash is
  dropped and the refusal is silent -- the person clicks, nothing happens,
  and nothing says why. So a component hands the sentence to its parent
  instead, which is the only process with a flash to put it in.

  Both pages handle `{:flash, :error, message}` for this reason.
  """
  @spec error(Socket.t(), term()) :: Socket.t()
  def error(socket, reason) do
    message = Error.from(reason).message

    if component?(socket) do
      send(self(), {:flash, :error, message})
      socket
    else
      Phoenix.LiveView.put_flash(socket, :error, message)
    end
  end

  # `@myself` is assigned only inside a `live_component`.
  defp component?(socket), do: Map.has_key?(socket.assigns, :myself)
end
