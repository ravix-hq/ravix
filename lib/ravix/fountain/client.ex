defmodule Ravix.Fountain.Client do
  @moduledoc """
  This server's Fountain connection: where it is, and the one key everybody
  runs on.

  Built from `Ravix.Config.fountain/0` by `Ravix.Fountain.client/0`, or by a
  test with the fake transport. A deployment without a key still gets a client,
  one with `http: nil`, so that every call answers `{:error, {:unconfigured, :fountain}}`
  instead of crashing; the pages say "no machines" and nothing else breaks.

  The SDK's own `Fountain.new/1` is deliberately not used: it falls back to
  `FOUNTAIN_API_KEY`, `FOUNTAIN_TOKEN` and `~/.fountain/credentials`, and a
  Ravix whose config says "no key" must not quietly pick one up from the
  operator's shell. The `Fountain.Config` is built here, from our config alone.

  `:http` is excluded from `Inspect` because the key is three structs down
  inside it (`Fountain.HTTP` holds a `Fountain.Config`, which holds
  `api_key`) and the SDK does not redact its own. A client is passed as an
  argument to most of `Ravix.Fountain`, so anything that inspects one --- a
  crash report, a log line, `dbg/1` --- would otherwise print the key every
  machine on this deployment runs on. `configured?/1` is the question
  callers actually ask of it, and it survives the redaction.
  """

  @derive {Inspect, except: [:http]}

  @type t :: %__MODULE__{http: Fountain.HTTP.t() | nil, base_url: String.t()}

  defstruct [:http, :base_url]

  @default_timeout 60_000

  @doc """
  A client for `base_url` on `api_key`, or an unconfigured one when the key is nil.

  Options: `:transport` (a module with the shape of `Fountain.HTTP.Finch`;
  tests pass the fake) and `:timeout` in milliseconds (default sixty seconds,
  what the TypeScript gave `fetch`).
  """
  @spec new(String.t(), String.t() | nil, keyword()) :: t()
  def new(base_url, api_key, opts \\ [])

  def new(base_url, nil, _opts), do: %__MODULE__{http: nil, base_url: trim(base_url)}
  def new(base_url, "", _opts), do: %__MODULE__{http: nil, base_url: trim(base_url)}

  def new(base_url, api_key, opts) when is_binary(api_key) do
    base_url = trim(base_url)

    config = %Fountain.Config{
      base_url: base_url,
      api_key: api_key,
      app_url: "",
      parent_conversation_id: nil
    }

    http =
      Fountain.HTTP.new(config,
        transport: Keyword.get(opts, :transport, Fountain.HTTP.Finch),
        timeout: Keyword.get(opts, :timeout, @default_timeout)
      )

    %__MODULE__{http: http, base_url: base_url}
  end

  @doc "Whether this client holds a key at all."
  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{http: http}), do: not is_nil(http)

  defp trim(url), do: String.trim_trailing(url, "/")
end
