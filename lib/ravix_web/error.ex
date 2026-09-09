defmodule RavixWeb.Error do
  @moduledoc """
  A context's refusal, as a status, a code and a sentence.

  Contexts return tagged tuples and never speak HTTP. The few routes that
  still answer over HTTP (the auth controller, the preview gateway) need the
  vocabulary `HttpError` in `server/http.ts` had, and the LiveView pages need
  the sentence for a toast. `from/2` is the one place every shape
  `CONTRACTS.md` lists is turned into those three things, so a new error
  shape is added here once and every surface agrees on it.
  """

  alias Ravix.Fountain.Error, as: FountainError
  alias Ravix.GitHub.Error, as: GitHubError
  alias Ravix.Sprites.Error, as: SpritesError

  @type t :: %__MODULE__{status: pos_integer(), code: String.t(), message: String.t()}

  defstruct status: 500, code: "internal", message: "Something went wrong on the Ravix server."

  @typedoc """
  Options for `from/2`: `:what_for` finishes "could not reach GitHub to ..."
  for the client errors; `:noun` names what was not found ("project").
  """
  @type option :: {:what_for, String.t()} | {:noun, String.t()}

  @doc """
  The error for any reason a context returns.

    * `:not_found` is 404 `not_found`, "No such project." with `noun: "project"`.
    * `:unauthenticated` is 401 `unauthenticated`; `:reauthenticate` and
      `:no_token` (from `Ravix.Accounts.user_token/1`) are 401 `reauthenticate`.
    * `{:forbidden, message}` is 403 `owner_only`.
    * `{:conflict, code, message}` is 409; `{:unprocessable, code, message}` is 422.
    * `{:unavailable, message}` is 503 `unavailable`; `{:unavailable, code, message}`
      keeps its code (`no_github`, `no_fountain`).
    * `%Ravix.Fountain.Error{}` and `:unconfigured` go through
      `Ravix.Fountain.Error.as_http/2`; `%Ravix.GitHub.Error{}` through
      `Ravix.GitHub.Error.describe/2`; `%Ravix.Sprites.Error{}` keeps its status.
    * `%Ecto.Changeset{}` is 422 `invalid` with the first field error.
    * anything else is the 500 the TypeScript logged and hid.
  """
  @spec from(term(), [option()]) :: t()
  def from(reason, opts \\ [])

  def from(%__MODULE__{} = error, _opts), do: error

  def from(:not_found, opts) do
    noun = Keyword.get(opts, :noun)
    message = if noun, do: "No such #{noun}.", else: "No such thing here."
    %__MODULE__{status: 404, code: "not_found", message: message}
  end

  def from(:unauthenticated, _opts),
    do: %__MODULE__{status: 401, code: "unauthenticated", message: "Sign in with GitHub."}

  def from(:session_ended, _opts),
    do: %__MODULE__{
      status: 401,
      code: "unauthenticated",
      message: "That session has ended. Sign in again."
    }

  def from(reason, _opts) when reason in [:reauthenticate, :no_token],
    do: %__MODULE__{status: 401, code: "reauthenticate", message: "Sign in with GitHub again."}

  def from({:forbidden, message}, _opts),
    do: %__MODULE__{status: 403, code: "owner_only", message: message}

  def from({:conflict, code, message}, _opts),
    do: %__MODULE__{status: 409, code: to_string(code), message: message}

  def from({:unprocessable, code, message}, _opts),
    do: %__MODULE__{status: 422, code: to_string(code), message: message}

  def from({:unavailable, message}, _opts) when is_binary(message),
    do: %__MODULE__{status: 503, code: "unavailable", message: message}

  def from({:unavailable, code, message}, _opts),
    do: %__MODULE__{status: 503, code: to_string(code), message: message}

  def from(%FountainError{} = error, opts), do: fountain(error, opts)
  def from(:unconfigured, opts), do: fountain(:unconfigured, opts)

  def from(%GitHubError{} = error, opts) do
    {status, code, message} = GitHubError.describe(error, what_for(opts))
    %__MODULE__{status: status, code: code, message: message}
  end

  def from(%SpritesError{status: status, message: message}, _opts) do
    %__MODULE__{
      status: if(is_integer(status) and status > 0, do: status, else: 502),
      code: "sprites_error",
      message: message
    }
  end

  def from(%Ecto.Changeset{} = changeset, _opts) do
    %__MODULE__{status: 422, code: "invalid", message: changeset_message(changeset)}
  end

  def from(_other, _opts), do: %__MODULE__{}

  @doc "Answer `conn` with the error as JSON (`{error, message}`), as `errorResponse` did, and halt."
  @spec send_json(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_json(conn, reason) do
    error = from(reason)

    conn
    |> Plug.Conn.put_status(error.status)
    |> Phoenix.Controller.json(%{error: error.code, message: error.message})
    |> Plug.Conn.halt()
  end

  defp fountain(error, opts) do
    %{status: status, code: code, message: message} = FountainError.as_http(error, what_for(opts))
    %__MODULE__{status: status, code: code, message: message}
  end

  defp what_for(opts), do: Keyword.get(opts, :what_for, "do that")

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, values} ->
      Enum.reduce(values, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.find_value("The request is not valid.", fn
      {field, [message | _]} -> "#{field} #{message}."
      _ -> nil
    end)
  end
end
