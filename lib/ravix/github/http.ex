defmodule Ravix.GitHub.HTTP do
  @moduledoc """
  The one request.

  Every call to the GitHub API goes through `request/4`: the headers GitHub
  wants, a twenty-second budget, the body as JSON in and out, and an error
  that keeps GitHub's own message. Rate limits are remembered per
  installation in `Ravix.GitHub.Cache`, so once GitHub says stop, nothing
  else for that installation is even sent until the reset.

  `Application.get_env(:ravix, :req_options, [])` is merged into every
  request, which is how the tests route it through `Req.Test`.
  """

  alias Ravix.Config.GitHubApp
  alias Ravix.GitHub.{Cache, Clock, Error}

  @user_agent "ravix (+https://app.ravix.sh)"
  @timeout_ms 20_000

  @type option ::
          {:auth, String.t()}
          | {:json, term()}
          | {:installation_id, integer()}
          | {:accept, String.t()}

  @doc """
  One request to GitHub.

  `path` is relative to the App's API URL unless it is absolute. `:auth` is
  the whole Authorization header value. `:json` is a body to send. With
  `:installation_id`, a rate limit GitHub answers with is remembered against
  that installation, and a remembered one is answered without a request.
  """
  @spec request(GitHubApp.t(), :get | :post, String.t(), [option()]) ::
          {:ok, term()} | {:error, Error.t()}
  def request(%GitHubApp{} = app, method, path, opts \\ []) do
    installation_id = Keyword.get(opts, :installation_id)

    with :ok <- check_rate_limit(app, installation_id),
         {:ok, response} <- send_request(app, method, path, opts) do
      interpret(app, installation_id, response)
    end
  end

  @doc "The user agent every request identifies itself with."
  @spec user_agent() :: String.t()
  def user_agent, do: @user_agent

  @doc "The options every Req call is built on, with the test overrides merged in."
  @spec req_options(keyword()) :: keyword()
  def req_options(opts) do
    Keyword.merge(opts, Application.get_env(:ravix, :req_options, []))
  end

  # ── the request ────────────────────────────────────────────────────

  defp check_rate_limit(_app, nil), do: :ok

  defp check_rate_limit(app, installation_id) do
    case Cache.rate_limit(app.app_id, installation_id) do
      {:ok, until_ms, error} ->
        if until_ms > Clock.now_ms() do
          {:error, error}
        else
          Cache.clear_rate_limit(app.app_id, installation_id)
        end

      :error ->
        :ok
    end
  end

  defp send_request(app, method, path, opts) do
    url = if String.starts_with?(path, "http"), do: path, else: app.api_url <> path

    headers = [
      {"accept", Keyword.get(opts, :accept, "application/vnd.github+json")},
      {"authorization", Keyword.fetch!(opts, :auth)},
      {"user-agent", @user_agent},
      {"x-github-api-version", "2022-11-28"}
    ]

    base = [
      method: method,
      url: url,
      headers: headers,
      receive_timeout: @timeout_ms,
      retry: false,
      decode_body: false
    ]

    base =
      case Keyword.fetch(opts, :json) do
        {:ok, body} -> Keyword.put(base, :json, body)
        :error -> base
      end

    case Req.request(req_options(base)) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, exception} ->
        {:error, %Error{status: nil, message: "Could not reach GitHub: " <> describe(exception)}}
    end
  end

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)

  # ── the answer ─────────────────────────────────────────────────────

  defp interpret(_app, _installation_id, %Req.Response{status: 204}), do: {:ok, nil}

  defp interpret(_app, _installation_id, %Req.Response{status: status, body: body})
       when status in 200..299 do
    case decode(body) do
      # Every caller reads the answer as JSON: `body["token"]`, or
      # `Enum.map(body, &Shapes.pull_ref/1)`. A 200 carrying something else --
      # a proxy interstitial, a WAF challenge, a maintenance page -- used to
      # reach them as a bare string and raise `Access`/`Enumerable` errors out
      # of the context, past the `{:ok, _} | {:error, _}` this promises.
      raw when is_binary(raw) ->
        {:error,
         %Error{
           status: status,
           message: "GitHub answered #{status} with something that is not JSON."
         }}

      value ->
        {:ok, value}
    end
  end

  defp interpret(app, installation_id, %Req.Response{status: status, body: body} = response) do
    message = error_message(status, body)

    if limited?(status, message, response) do
      until = retry_until(response)
      error = %Error{status: status, message: message, retry_at_ms: until}
      if installation_id, do: Cache.put_rate_limit(app.app_id, installation_id, until, error)
      {:error, error}
    else
      {:error, %Error{status: status, message: message}}
    end
  end

  defp decode(""), do: nil
  defp decode(nil), do: nil

  defp decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      {:error, _} -> text
    end
  end

  defp decode(other), do: other

  # GitHub's message, plus the first detail when it names one; otherwise the
  # status line is the whole story.
  defp error_message(status, body) do
    fallback = "GitHub said #{status}."

    with true <- is_binary(body),
         {:ok, %{} = parsed} <- Jason.decode(body) do
      message = if is_binary(parsed["message"]), do: parsed["message"], else: fallback

      case parsed["errors"] do
        [%{"message" => first} | _] when is_binary(first) -> message <> " " <> first
        _ -> message
      end
    else
      _ -> fallback
    end
  end

  defp limited?(429, _message, _response), do: true

  defp limited?(403, message, response) do
    header(response, "x-ratelimit-remaining") == "0" or
      header(response, "retry-after") != nil or
      Regex.match?(~r/rate limit/i, message)
  end

  defp limited?(_status, _message, _response), do: false

  # Whichever is later: what Retry-After asks for (a minute if it says
  # nothing), or the window's own reset.
  defp retry_until(response) do
    now = Clock.now_ms()
    retry_seconds = number(header(response, "retry-after"))
    reset_ms = number(header(response, "x-ratelimit-reset")) * 1000
    wait_ms = if retry_seconds > 0, do: retry_seconds * 1000, else: 60_000
    max(now + wait_ms, reset_ms)
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp number(nil), do: 0

  defp number(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> 0
    end
  end
end
