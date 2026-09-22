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

  # Six seconds: long enough to read a sentence, short enough that a toast
  # nobody dismissed is not still there an hour later.
  @notice_ms 6_000

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

  See `flash/3` for where the sentence ends up.
  """
  @spec error(Socket.t(), term()) :: Socket.t()
  def error(socket, reason), do: flash(socket, :error, Error.from(reason).message)

  @doc """
  Flash the one sentence for work that exited before it could answer.

  A `handle_async/3` clause matching `{:exit, reason}` is a page whose task
  crashed, was killed or lost the instance it ran on. It used to be five
  clauses in five modules, four of them carrying the same string, and each
  a chance for the next one to say it differently. The sentence is
  `RavixWeb.Error`'s, as `{:async_exit, reason}`; the reason is the
  refusal's payload, which `Error.from/2` never logs and the task's own
  crash report already did.

  Two arguments, because `exit/1` is `Kernel`'s.
  """
  @spec exit(Socket.t(), term()) :: Socket.t()
  def exit(socket, reason), do: error(socket, {:async_exit, reason})

  @doc """
  Put `message` in the flash that is actually rendered.

  A `live_component` cannot do this itself. `Phoenix.LiveView.put_flash/3`
  inside one changes a socket the page never renders, so the flash is
  dropped and the refusal is silent -- the person clicks, nothing happens,
  and nothing says why. So a component hands the sentence to its parent
  instead, which is the only process with a flash to put it in.

  A nested LiveView is in the same position for a different reason: its
  flash is its own, and the page's `Layouts.app` never sees it. The track
  page used to draw a second toast stack of its own for exactly this, at
  the same corner as the workspace's, so two toasts could land on top of
  one another and the nested one said nothing to a screen reader. The
  sentence goes up to `socket.parent_pid` instead, and there is one stack.

  Every page handles `{:flash, kind, message}` for both reasons.

  A notice (`:info`) is news, not a fault, so the page that renders it lets
  it go after `notice_ms/0` (`after:` names another delay): a
  `{:clear_flash, :info, message}` is sent to that process, and
  `clear_notice/3` drops the flash only if it still says the same thing. An
  error stays until somebody dismisses it.
  """
  @spec flash(Socket.t(), :info | :error, String.t(), after: non_neg_integer()) :: Socket.t()
  def flash(socket, kind, message, opts \\ []) when kind in [:info, :error] do
    cond do
      component?(socket) ->
        send(self(), {:flash, kind, message})
        socket

      is_pid(socket.parent_pid) ->
        send(socket.parent_pid, {:flash, kind, message})
        socket

      kind == :info ->
        delay = Keyword.get(opts, :after, notice_ms())
        Process.send_after(self(), {:clear_flash, :info, message}, delay)
        Phoenix.LiveView.put_flash(socket, :info, message)

      true ->
        Phoenix.LiveView.put_flash(socket, :error, message)
    end
  end

  @doc "How long a notice stays before `flash/3` lets it go."
  @spec notice_ms() :: pos_integer()
  def notice_ms, do: @notice_ms

  @doc """
  The timer from `flash/3` arriving. The flash goes only if it still holds
  `message`: a newer notice has its own timer, and must not be cut short by
  the one that belonged to the notice it replaced.
  """
  @spec clear_notice(Socket.t(), :info | :error, String.t()) :: Socket.t()
  def clear_notice(socket, kind, message) do
    if Phoenix.Flash.get(socket.assigns.flash, kind) == message,
      do: Phoenix.LiveView.clear_flash(socket, kind),
      else: socket
  end

  # `@myself` is assigned only inside a `live_component`.
  defp component?(socket), do: Map.has_key?(socket.assigns, :myself)
end
