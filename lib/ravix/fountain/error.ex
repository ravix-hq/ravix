defmodule Ravix.Fountain.Error do
  @moduledoc """
  A Fountain failure, preserving what the caller needs.

  The status and the code are Fountain's own (`sandbox_at_capacity`,
  `conversation_busy`, `sandbox_identity_mismatch`, ...); the message is
  Fountain's `message` when it sent one, else the code, else the SDK's line.
  `kind` is the SDK's classification and is only read for one thing here:
  `:connection` (status 0) is "could not reach Fountain", which is a different
  answer from "Fountain said no".

  `as_http/2` is `asHttpError` from `server/fountain.ts`: the same failure as
  one of ours, in the vocabulary an HTTP status is right for. It returns a map
  rather than a `RavixWeb.Error` so this module does not depend on the web
  layer; the gateway and the controllers wrap it.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          code: String.t() | nil,
          message: String.t(),
          kind: atom()
        }

  @type http :: %{status: pos_integer(), code: String.t(), message: String.t()}

  defstruct status: 0, code: nil, message: "", kind: :api

  @busy_codes ~w(sandbox_at_capacity conversation_busy)

  @doc "The SDK's error as ours."
  @spec from_sdk(Fountain.Error.t()) :: t()
  def from_sdk(%Fountain.Error{} = error) do
    %__MODULE__{
      status: error.status || 0,
      code: error.code,
      message: message_of(error),
      kind: error.kind || :api
    }
  end

  @doc """
  A machine already taking a turn.

  Fountain can reject an idle-looking track because another turn took the
  sandbox's capacity meanwhile. The prompt queue treats this as safe to retry
  rather than as a failed delivery.
  """
  @spec busy?(t()) :: boolean()
  def busy?(%__MODULE__{status: status, code: code}),
    do: status in 400..499 and code in @busy_codes

  @doc "Fountain refused the request outright: a 4xx that is not a capacity problem."
  @spec rejected?(t()) :: boolean()
  def rejected?(%__MODULE__{status: status}), do: status in 400..499

  @doc "Fountain could not be reached at all (nothing was sent, or nothing came back)."
  @spec unreachable?(t()) :: boolean()
  def unreachable?(%__MODULE__{status: 0}), do: true
  def unreachable?(%__MODULE__{kind: :connection}), do: true
  def unreachable?(%__MODULE__{}), do: false

  @doc """
  A Fountain failure as one of ours, preserving what the caller needs.

  A rejected key is this deployment's problem, not the person's, so it is a 502
  rather than a 401 that would send them to sign in again. Capacity and identity
  conflicts are 409s with codes the browser knows. Everything else keeps its
  status, except that Fountain's 5xx becomes our 502: it was upstream that failed.

  A deployment with no Fountain at all is not a Fountain failure and is not
  here: that is `{:unconfigured, :fountain}`, and `RavixWeb.Error` holds its
  one sentence beside the other two providers'.
  """
  @spec as_http(t(), String.t()) :: http()
  def as_http(%__MODULE__{status: status}, _what_for) when status in [401, 403] do
    %{
      status: 502,
      code: "fountain_rejected",
      message:
        "Fountain rejected this deployment's key. Ravix cannot build machines until that is fixed."
    }
  end

  def as_http(%__MODULE__{code: "sandbox_at_capacity"}, _what_for) do
    %{
      status: 409,
      code: "machine_busy",
      message: "This machine is already taking a turn. One track at a time. Yours is queued."
    }
  end

  def as_http(%__MODULE__{code: "sandbox_identity_mismatch"}, _what_for) do
    %{
      status: 409,
      code: "identity_mismatch",
      message:
        "This project's machine no longer matches its identity. Rebuild it from the project menu."
    }
  end

  def as_http(%__MODULE__{} = error, what_for) do
    if unreachable?(error) do
      %{
        status: 502,
        code: "fountain_unreachable",
        message: "Could not reach Fountain to #{what_for}."
      }
    else
      %{
        status: if(error.status >= 500, do: 502, else: error.status),
        code: error.code || "fountain_error",
        message: error.message
      }
    end
  end

  defp message_of(%Fountain.Error{body: %{"message" => message}}) when is_binary(message),
    do: message

  defp message_of(%Fountain.Error{code: code}) when is_binary(code), do: code
  defp message_of(%Fountain.Error{message: message}) when is_binary(message), do: message
  defp message_of(%Fountain.Error{status: status}), do: "HTTP #{status}"
end
