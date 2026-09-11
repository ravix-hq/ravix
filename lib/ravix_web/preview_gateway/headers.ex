defmodule RavixWeb.PreviewGateway.Headers do
  @moduledoc """
  What crosses the gateway in each direction, and what must not.

  Towards the app: hop-by-hop headers describe this connection rather than
  the request, `authorization` and the `forwarded` family would let a browser
  speak for the gateway, and `accept-encoding` is pinned to identity so HTML
  can be rewritten in flight. The gateway's own cookies and the Ravix session
  cookie are cut out of `cookie`: an app running someone's branch never
  learns a credential for anything but itself.

  Towards the browser: the same hop-by-hop set, `clear-site-data` (an app must
  not be able to sign the person out of the gateway) and `alt-svc`. An app
  cannot set the gateway's cookies or the app's session cookie, nor set any
  cookie on a parent domain (a `Domain` attribute is stripped however it is
  spelled, so every cookie stays host-only). Redirects to
  `localhost` are rewritten to the preview origin, since dev servers name
  themselves that way. Every answer is `no-store` and `no-referrer`:
  authenticated content must never survive access loss in a shared cache, and
  the preview host must not leak into another site's logs.
  """

  @cookie "__Host-ravix_preview"
  @local_cookie "ravix_preview_local"
  @private_cookies [@cookie, @local_cookie]

  @hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @response_drop @hop ++ ~w(clear-site-data alt-svc)

  @type headers :: [{String.t(), String.t()}]

  @doc """
  The name of the gateway's cookie for a preview protocol.

  `__Host-` cookies need `Secure`, which plain-HTTP `*.localhost` previews
  cannot set, so local development uses a plainly named one.
  """
  @spec cookie_name(:http | :https) :: String.t()
  def cookie_name(:http), do: @local_cookie
  def cookie_name(_), do: @cookie

  @typedoc "Whether these headers open a plain request or a WebSocket upgrade."
  @type kind :: :request | :upgrade

  @doc "The browser's request headers as the app may see them."
  @spec upstream_headers(headers(), String.t(), kind()) :: headers()
  def upstream_headers(headers, host, kind \\ :request) when kind in [:request, :upgrade] do
    connection = connection_tokens(headers)

    kept =
      for {name, value} <- headers,
          name not in ["host", "cookie", "accept-encoding"],
          keep_upstream?(name, connection),
          do: {name, value}

    cookie =
      headers
      |> Enum.filter(fn {name, _} -> name == "cookie" end)
      |> Enum.map_join("; ", fn {_, value} -> value end)
      |> scrub_cookie()

    kept ++
      cookie_header(cookie) ++
      [{"host", host}, {"accept-encoding", "identity"}] ++
      if(kind == :upgrade, do: [{"connection", "Upgrade"}, {"upgrade", "websocket"}], else: [])
  end

  @doc "The app's response headers as the browser may see them."
  @spec response_headers(headers(), String.t()) :: headers()
  def response_headers(headers, origin) do
    headers = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)
    connection = connection_tokens(headers)

    kept =
      for {name, value} <- headers,
          name not in @response_drop,
          name not in connection,
          name not in ["referrer-policy", "cache-control"],
          reduce: [] do
        acc -> keep_response({name, value}, origin, acc)
      end

    Enum.reverse(kept) ++
      [{"referrer-policy", "no-referrer"}, {"cache-control", "no-store"}]
  end

  @doc "The value of one cookie in a `cookie` header, or the empty string."
  @spec cookie(headers(), String.t()) :: String.t()
  def cookie(headers, name) do
    headers
    |> Enum.filter(fn {key, _} -> key == "cookie" end)
    |> Enum.flat_map(fn {_, value} -> String.split(value, ";") end)
    |> Enum.map(&String.trim/1)
    |> Enum.find_value("", fn pair ->
      case String.split(pair, "=", parts: 2) do
        [^name, value] -> value
        _ -> nil
      end
    end)
  end

  defp keep_response({"set-cookie", cookie}, _origin, acc) do
    if private_cookie?(cookie),
      do: acc,
      else: [{"set-cookie", strip_domain(cookie)} | acc]
  end

  defp keep_response({"location", location}, origin, acc),
    do: [{"location", rewrite_location(location, origin)} | acc]

  defp keep_response(header, _origin, acc), do: [header | acc]

  defp keep_upstream?(name, connection) do
    name not in @hop and name not in connection and name != "authorization" and
      name != "forwarded" and not String.starts_with?(name, "x-forwarded-")
  end

  defp connection_tokens(headers) do
    headers
    |> Enum.filter(fn {name, _} -> name == "connection" end)
    |> Enum.flat_map(fn {_, value} -> String.split(value, ",") end)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  defp scrub_cookie(cookie) do
    cookie
    |> String.split(";")
    |> Enum.reject(fn part -> private_cookie?(part) end)
    |> Enum.join(";")
  end

  defp cookie_header(""), do: []
  defp cookie_header(cookie), do: [{"cookie", cookie}]

  # RFC 6265 5.2 splits each attribute on its first `=` and trims whitespace
  # from both halves, so `Domain =x`, `domain\t= x` and `Domain=x` are one
  # attribute to a browser. Anchoring the pattern on `=` alone let a single
  # space through, which is enough to put a cookie on the registrable domain.
  defp strip_domain(cookie), do: Regex.replace(~r/;\s*domain\s*=[^;]*/i, cookie, "")

  defp private_cookie?(pair) do
    name = pair |> String.split("=", parts: 2) |> hd() |> String.trim()
    name in private_cookies()
  end

  # The app's session cookie is named by the endpoint, so this cannot drift
  # from what the app actually sets.
  defp private_cookies, do: [RavixWeb.Endpoint.session_cookie_name() | @private_cookies]

  defp rewrite_location(location, origin) do
    if Regex.match?(~r{^https?://(localhost|127\.0\.0\.1)(:\d+)?(/|$)}i, location) do
      uri = URI.parse(location)

      origin <>
        (uri.path || "/") <>
        if(uri.query, do: "?" <> uri.query, else: "") <>
        if(uri.fragment, do: "#" <> uri.fragment, else: "")
    else
      location
    end
  end
end
