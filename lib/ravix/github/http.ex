defmodule Ravix.GitHub.HTTP do
  @moduledoc """
  The one request.

  Every call to GitHub goes through `request/4`: the headers GitHub wants, a
  twenty-second budget, the body as JSON in and out, the span, and an error
  that keeps GitHub's own message. Rate limits are remembered per
  credential in `Ravix.GitHub.Cache`, so once GitHub says stop, nothing
  else for that credential is even sent until the reset.

  That includes the one call that is not to the API host: the OAuth code
  exchange at `web_url/login/oauth/access_token`, which authenticates by the
  client secret in its body rather than a header. It used to build its own
  `Req` call beside this one, with no span and a second copy of the
  transport error, so a sign-in that GitHub was slow to answer was the one
  request to GitHub a trace could not see.

  `Application.get_env(:ravix, :req_options, [])` is merged into every
  request, which is how the tests route it through `Req.Test`.
  """

  alias Ravix.Clock
  alias Ravix.Config.GitHubApp
  alias Ravix.GitHub.{Cache, Error, Reads}
  alias Ravix.Trace

  @user_agent "ravix (+https://app.ravix.sh)"
  @timeout_ms 20_000

  @type option ::
          {:user_token, String.t()}
          | {:auth, String.t()}
          | {:json, term()}
          | {:installation_id, integer()}
          | {:accept, String.t()}
          | {:cache_ttl, non_neg_integer()}

  @doc """
  One request to GitHub.

  `path` is relative to the App's API URL unless it is absolute. `:auth` is
  the whole Authorization header value, and is left out only by the OAuth
  exchange, whose credential travels in the body. `:json` is a body to send;
  `:accept` replaces the API's media type for a host that speaks plain JSON.
  With `:installation_id`, a rate limit GitHub answers with is remembered
  against that installation, and a remembered one is answered without a
  request. `:user_token` authenticates as a user and applies the same cooldown
  across all endpoints read with that credential, including repository listing.
  """
  @spec request(GitHubApp.t(), :get | :post, String.t(), [option()]) ::
          {:ok, term()} | {:error, Error.t()}
  def request(%GitHubApp{} = app, method, path, opts \\ []) do
    scope = scope(opts)

    # Every GitHub request funnels through here. The span covers the rate-limit
    # check as well as the call, on purpose: a request answered from a
    # remembered limit without touching the network is the interesting case, and
    # `ravix.rate_limited` is how a trace says that is what happened rather
    # than showing an implausibly fast 403.
    Trace.span(
      "github.request",
      %{"http.request.method" => method, "url.path" => path},
      fn -> request_or_cached(app, scope, method, path, opts) end
    )
  end

  defp request_or_cached(app, scope, :get, path, opts) do
    case Keyword.fetch(opts, :cache_ttl) do
      {:ok, ttl} when is_integer(ttl) and ttl >= 0 and not is_nil(scope) ->
        key = {app.app_id, app.api_url, scope, path, Keyword.get(opts, :accept)}

        Reads.fetch(
          key,
          ttl,
          fn headers -> attempt(app, scope, :get, path, Keyword.put(opts, :headers, headers)) end,
          &interpret(app, scope, &1)
        )

      _ ->
        uncached(app, scope, :get, path, opts)
    end
  end

  defp request_or_cached(app, scope, method, path, opts),
    do: uncached(app, scope, method, path, opts)

  defp uncached(app, scope, method, path, opts) do
    with {:ok, response} <- attempt(app, scope, method, path, opts),
         do: interpret(app, scope, response)
  end

  defp attempt(app, scope, method, path, opts) do
    case check_rate_limit(app, scope) do
      :ok ->
        with {:ok, response} <- send_request(app, method, path, opts) do
          received(app, scope, response)
        end

      # A limit GitHub gave us earlier, answered without a request. Said on the
      # span, because the alternative is a 403 or a 429 that took no time and
      # that no reader can tell apart from one that did.
      {:error, _} = refused ->
        Trace.annotate(%{"ravix.rate_limited" => true})
        refused
    end
  end

  defp received(app, scope, response) do
    observe(app, scope, response)

    if response.status in 200..299 or response.status == 304,
      do: {:ok, response},
      else: interpret(app, scope, response)
  end

  # ── the request ────────────────────────────────────────────────────

  defp check_rate_limit(_app, nil), do: :ok

  defp check_rate_limit(app, scope) do
    case Cache.rate_limit(app.app_id, scope) do
      {:ok, until_ms, error} ->
        if until_ms > Clock.now_ms() do
          {:error, error}
        else
          :ok
        end

      :error ->
        :ok
    end
  end

  defp send_request(app, method, path, opts) do
    url = if String.starts_with?(path, "http"), do: path, else: app.api_url <> path

    headers =
      [
        {"accept", Keyword.get(opts, :accept, "application/vnd.github+json")},
        {"user-agent", @user_agent},
        {"x-github-api-version", "2022-11-28"}
      ] ++ auth_header(opts) ++ Keyword.get(opts, :headers, [])

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

  defp scope(opts) do
    case Keyword.fetch(opts, :user_token) do
      {:ok, token} -> Cache.user_scope(token)
      :error -> Keyword.get(opts, :installation_id)
    end
  end

  defp auth_header(opts) do
    opts =
      case Keyword.fetch(opts, :user_token) do
        {:ok, token} -> Keyword.put(opts, :auth, "Bearer " <> token)
        :error -> opts
      end

    case Keyword.fetch(opts, :auth) do
      {:ok, auth} -> [{"authorization", auth}]
      :error -> []
    end
  end

  # The options every Req call is built on, with the test overrides merged in.
  defp req_options(opts), do: Keyword.merge(opts, Application.get_env(:ravix, :req_options, []))

  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)

  # Only numeric budget fields and the credential kind leave this boundary.
  # Never annotate an Authorization header, token fingerprint or response body.
  defp observe(app, scope, response) do
    Trace.annotate(
      %{
        "http.response.status_code" => response.status,
        "github.budget_scope" => credential_kind(scope),
        "github.rate_limit.limit" => integer_header(response, "x-ratelimit-limit"),
        "github.rate_limit.remaining" => integer_header(response, "x-ratelimit-remaining"),
        "github.rate_limit.used" => integer_header(response, "x-ratelimit-used"),
        "github.rate_limit.reset" => integer_header(response, "x-ratelimit-reset")
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    )

    # The last successful request still succeeds; the next request waits for
    # reset instead of spending a request to discover the exhausted budget.
    reset = integer_header(response, "x-ratelimit-reset")

    if scope && (response.status in 200..299 or response.status == 304) &&
         integer_header(response, "x-ratelimit-remaining") == 0 &&
         is_integer(reset) && reset * 1000 > Clock.now_ms() do
      until = reset * 1000

      error = %Error{
        status: 429,
        message: "GitHub's request budget is exhausted.",
        retry_at_ms: until
      }

      Cache.put_rate_limit(app.app_id, scope, until, error)
    end
  end

  defp credential_kind({:user, _}), do: :user
  defp credential_kind(nil), do: :app
  defp credential_kind(_), do: :installation

  defp integer_header(response, name) do
    case header(response, name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> n
          _ -> nil
        end
    end
  end

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
