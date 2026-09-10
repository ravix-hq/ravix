defmodule Ravix.GitHub.Error do
  @moduledoc """
  A GitHub failure, keeping the part a person can act on.

  `status` is the HTTP status GitHub answered with, or `nil` when there was no
  answer at all (the network, a timeout). `retry_at_ms` is set only for a rate
  limit, and is the earliest moment another request for that installation is
  worth making; `Ravix.GitHub` refuses to send any before then.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          message: String.t(),
          retry_at_ms: integer() | nil
        }

  defexception [:status, :message, :retry_at_ms]

  @doc """
  The status, code and message the web layer should answer with.

  A port of `asHttpError` in `server/github.ts`. `what_for` finishes the
  sentence "GitHub would not let Ravix ...", so the person reading the
  message knows which step it was: "list repositories", "open a pull request".
  """
  @spec describe(term(), String.t()) :: {pos_integer(), String.t(), String.t()}
  def describe(%__MODULE__{retry_at_ms: retry_at} = _error, _what_for)
      when is_integer(retry_at) and retry_at > 0 do
    at = retry_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    {503, "github_rate_limited",
     "GitHub's request limit was reached. Ravix will retry after #{at}."}
  end

  def describe(%__MODULE__{status: status, message: message}, what_for)
      when status in [401, 403] do
    {502, "github_rejected", "GitHub would not let Ravix #{what_for}: #{message}"}
  end

  def describe(%__MODULE__{status: 404, message: message}, _what_for),
    do: {404, "github_not_found", message}

  def describe(%__MODULE__{status: status, message: message}, _what_for)
      when is_integer(status) and status > 0 do
    {if(status >= 500, do: 502, else: status), "github_error", message}
  end

  def describe(_other, what_for),
    do: {502, "github_unreachable", "Could not reach GitHub to #{what_for}."}
end
