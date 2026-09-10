defmodule RavixWeb.PreviewGateway do
  @moduledoc """
  The track-preview gateway: one host per track, in front of the app running
  in its sprite.

  Mounted in the endpoint before anything else, it owns every request whose
  Host is `<name>.<PREVIEW_DOMAIN>` and leaves the rest to the app, so a
  preview host never meets the app's session or static files. The
  TypeScript needed a second server and a front to do this; here the Host
  match is the whole of it.

  What happens to a preview request, in order:

    1. The host names a preview row, and its track is open.
    2. The two unauthenticated control routes: `/__ravix/open`, which reads
       a one-minute ticket out of the URL fragment (never in logs or a
       Referer), and `/__ravix/exchange`, which trades it, on the preview's
       own origin only and once only, for a host-only, HttpOnly session
       cookie bound to the person's Ravix session.
    3. That cookie's grant, checked on every request: it exists, the Ravix
       session is alive, the person still has access to an open track.
    4. Same-origin writes and upgrades, and a refusal of anything the
       browser marks cross-site or same-site, so previews that happen to
       share a registrable domain cannot forge each other's requests.
    5. The starting page, status, heartbeat and the injected activity
       script; then, for a ready preview, a streaming reverse proxy over the
       sprite tunnel (`Ravix.Sprites.Tunnel`), rewriting HTML in flight and
       relaying WebSockets frame for frame. Open connections are watched and
       cut when access ends.

  Everything Ravix-specific comes through `RavixWeb.PreviewGateway.Backend`;
  the tunnel module is read from application env so tests stand in a local
  upstream.
  """

  @behaviour Plug

  import Plug.Conn

  alias Ravix.Crypto
  alias RavixWeb.PreviewGateway.{Headers, Html, Relay, Watch}

  defmodule Error do
    @moduledoc "A refusal with the status the browser should see; `HttpError` in the TypeScript."
    defexception [:status, :code, :message]
    @type t :: %__MODULE__{status: pos_integer(), code: String.t(), message: String.t()}
  end

  defmodule ErrorAborted do
    @moduledoc """
    Drop the connection: the sprite stopped answering mid-body, the browser
    went away, or access was revoked while a body streamed. Raised only
    after headers are out, so the client sees a truncated response rather
    than a complete-looking one. Status 499 (the TypeScript's "client
    closed") keeps Bandit and Phoenix from logging it as a crash.
    """
    defexception message: "The preview connection was abandoned.", plug_status: 499
  end

  @control "/__ravix/"
  @start @control <> "start"
  @status @control <> "status"
  @heartbeat @control <> "heartbeat"
  @activity @control <> "activity.js"
  @max_frame 1024 * 1024
  @session_ttl_ms 12 * 60 * 60 * 1000
  @read_chunk 65_536
  # How long the gateway waits for the next piece of a response body. Without
  # it a sandbox that sends a head and then stops -- a hung dev server, or a
  # deliberate stall -- pins a Bandit connection process, a tunnel GenServer
  # and a Sprites WebSocket for as long as the node runs, and nothing else
  # cuts it: `Watch` only fires on revocation.
  @body_timeout 120_000
  @conn_key :preview_gateway_conn
  @generic "The preview did not answer. Return to the track to restart it or read its logs."
  @not_found "Preview not found."
  @unknown_control "Unknown preview control."

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with backend when is_atom(backend) and not is_nil(backend) <- backend(),
         cfg when is_map(cfg) <- backend.previews_config(),
         {:ok, name} <- preview_name(conn, cfg) do
      conn |> handle(backend, cfg, name) |> halt()
    else
      _ -> conn
    end
  end

  @doc "The configured backend, or nil when previews are not wired up."
  @spec backend() :: module() | nil
  def backend, do: Application.get_env(:ravix, :preview_backend)

  @doc "The sprite tunnel implementation; tests substitute a local one."
  @spec tunnel_module() :: module()
  def tunnel_module, do: Application.get_env(:ravix, :tunnel_module, Ravix.Sprites.Tunnel)

  defp tunnel_http, do: Module.concat(tunnel_module(), HTTP)

  defp preview_name(conn, cfg) do
    suffix = ".#{cfg.domain}#{cfg.public_port}"
    host = conn |> get_req_header("host") |> List.first("") |> String.downcase()

    if String.ends_with?(host, suffix) and byte_size(host) > byte_size(suffix),
      do: {:ok, binary_part(host, 0, byte_size(host) - byte_size(suffix))},
      else: :error
  end

  defp handle(conn, backend, cfg, name) do
    websocket? = header(conn, "upgrade") == "websocket"

    try do
      row = resolve_host!(backend, name)
      host = "#{row.hostname}.#{cfg.domain}#{cfg.public_port}"
      origin = "#{cfg.protocol}://#{host}"

      if websocket?,
        do: upgrade(conn, backend, cfg, row, host, origin),
        else: request(conn, backend, cfg, row, host, origin)
    rescue
      error in Error ->
        if websocket?, do: refuse_upgrade(conn, error), else: fail(conn, backend, error)
    end
  end

  # ── resolution and authorization ─────────────────────────────────────

  defp resolve_host!(backend, name) do
    case backend.resolve_host(name) do
      {:ok, row} ->
        case backend.assert_open(row.track_id) do
          :ok ->
            row

          {:error, reason} ->
            raise refusal(reason, 409, "closed_track", "This track is closed or being retired.")
        end

      :error ->
        raise Error, status: 404, code: "preview", message: @not_found
    end
  end

  defp authorize!(conn, backend, cfg, row) do
    hash =
      conn.req_headers |> Headers.cookie(Headers.cookie_name(cfg.protocol)) |> Crypto.sha256()

    grant = backend.get_grant(hash, row.track_id, :session, false)

    if grant && backend.allowed?(row, grant),
      do: grant,
      else:
        raise(Error,
          status: 401,
          code: "preview_signin",
          message: "Open this preview from your signed-in Ravix track."
        )
  end

  defp track!(backend, track_id) do
    backend.track(track_id) || raise Error, status: 404, code: "preview", message: @not_found
  end

  defp destination!(backend, track_id) do
    case backend.destination(track_id) do
      {:ok, _} -> :ok
      {:error, reason} -> raise refusal(reason, 502, "preview_unavailable", @generic)
    end
  end

  defp watch!(backend, row, grant, project_id) do
    case Watch.start(backend, row, grant, project_id) do
      {:ok, watch} ->
        watch

      :revoked ->
        raise Error,
          status: 401,
          code: "preview_signin",
          message: "Open this preview from your signed-in Ravix track."
    end
  end

  defp open_tunnel!(backend, row) do
    with sprites when is_map(sprites) <- backend.sprites_config(),
         {:ok, tunnel} <- tunnel_module().open(sprites, row.sprite, row.port, []) do
      tunnel
    else
      _ -> raise Error, status: 502, code: "preview_unavailable", message: @generic
    end
  end

  defp refusal(%{status: status, message: message}, _status, code, _message)
       when is_integer(status),
       do: %Error{status: status, code: code, message: message}

  defp refusal(_reason, status, code, message),
    do: %Error{status: status, code: code, message: message}

  # ── plain requests ───────────────────────────────────────────────────

  defp request(conn, backend, cfg, row, host, origin) do
    path = conn.request_path

    cond do
      path == @control <> "open" and conn.method == "GET" ->
        reply(conn, 200, open_page())

      path == @control <> "exchange" and conn.method == "POST" ->
        exchange(conn, backend, cfg, row, origin)

      true ->
        authorized(conn, backend, cfg, row, host, origin)
    end
  end

  defp exchange(conn, backend, cfg, row, origin) do
    if header(conn, "origin") != origin,
      do: raise(Error, status: 403, code: "origin", message: "Open previews from their own host.")

    {body, conn} = read_ticket!(conn)
    ticket = backend.get_grant(Crypto.sha256(body), row.track_id, :ticket, true)
    user = ticket && backend.session_user(ticket.session_hash)
    open? = user && match?({:ok, %{closed_at: nil}}, backend.track_access(user, row.track_id))

    unless open?,
      do:
        raise(Error,
          status: 401,
          code: "ticket",
          message: "This preview link expired. Open it again from Ravix."
        )

    token = Crypto.random_token()

    session = %{
      hash: Crypto.sha256(token),
      track_id: ticket.track_id,
      session_hash: ticket.session_hash,
      expires: System.system_time(:millisecond) + @session_ttl_ms,
      kind: :session
    }

    case backend.grant_session(session) do
      :ok -> :ok
      {:error, _} -> raise Error, status: 502, code: "preview_unavailable", message: @generic
    end

    secure = if cfg.protocol == :https, do: "; Secure", else: ""

    conn
    |> put_resp_header(
      "set-cookie",
      "#{Headers.cookie_name(cfg.protocol)}=#{token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200#{secure}"
    )
    |> reply(204, "")
  end

  defp read_ticket!(conn) do
    case read_body(conn, length: 128, read_length: 128) do
      {:ok, body, conn} when byte_size(body) <= 128 -> {body, conn}
      _ -> raise Error, status: 400, code: "ticket", message: "Invalid ticket."
    end
  end

  defp authorized(conn, backend, cfg, row, host, origin) do
    grant = authorize!(conn, backend, cfg, row)
    same_origin!(conn, origin)
    track = track!(backend, row.track_id)
    back = "#{backend.public_url()}/p/#{track.project_id}/t/#{track.id}"

    cond do
      String.starts_with?(conn.request_path, @control) ->
        control(conn, backend, row, back)

      row.state != :ready ->
        conn
        |> put_resp_header("location", @start)
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(302, "")

      true ->
        proxy(conn, backend, row, grant, track, host, origin)
    end
  end

  # Same-origin writes and upgrades also prevent cross-track CSRF when
  # wildcard hosts happen to share a registrable domain.
  defp same_origin!(conn, origin) do
    if conn.method not in ["GET", "HEAD"] and header(conn, "origin") != origin,
      do:
        raise(Error,
          status: 403,
          code: "origin",
          message: "Cross-origin preview writes are not allowed."
        )

    if header(conn, "sec-fetch-site") in ["cross-site", "same-site"],
      do: raise(Error, status: 403, code: "origin", message: "Open the preview directly.")
  end

  defp control(conn, backend, row, back) do
    case {conn.request_path, conn.method} do
      {@start, _} ->
        backend.touch(row.track_id)
        if row.state == :stopped, do: start_service(backend, row.track_id)
        reply(conn, 200, start_page(back))

      {@status, _} ->
        reply(conn, 200, Jason.encode!(backend.info(row.track_id)), "application/json")

      {@heartbeat, "POST"} ->
        if row.desired != :running,
          do:
            raise(Error,
              status: 409,
              code: "stopped",
              message: "Preview stopped. Open it from the track again."
            )

        backend.touch(row.track_id)
        reply(conn, 204, "")

      {@activity, _} ->
        reply(conn, 200, activity_script(back), "application/javascript; charset=utf-8")

      _ ->
        raise Error, status: 404, code: "preview", message: @unknown_control
    end
  end

  # Fire and forget, as the TypeScript's `void manager.startService(...)`.
  defp start_service(backend, track_id) do
    Task.Supervisor.start_child(Ravix.TaskSupervisor, fn -> backend.start_service(track_id) end)
  end

  # ── the reverse proxy ────────────────────────────────────────────────

  defp proxy(conn, backend, row, grant, track, host, origin) do
    destination!(backend, row.track_id)
    backend.touch(row.track_id)
    watch = watch!(backend, row, grant, track.project_id)

    try do
      tunnel = open_tunnel!(backend, row)
      tunnel_module = tunnel_module()
      Watch.attach(watch, fn -> tunnel_module.close(tunnel) end)

      try do
        headers = Headers.upstream_headers(conn.req_headers, host)
        body = if conn.method in ["GET", "HEAD"], do: nil, else: request_body(conn)

        response =
          tunnel_http().request(tunnel, conn.method, target(conn), headers, body,
            body_timeout: @body_timeout
          )

        conn = Process.delete(@conn_key) || conn

        case response do
          {:ok, status, response_headers, stream} ->
            respond(conn, status, response_headers, stream, origin)

          {:error, _reason} ->
            raise Error, status: 502, code: "preview_unavailable", message: @generic
        end
      after
        tunnel_module.close(tunnel)
      end
    after
      Watch.stop(watch)
    end
  end

  # The browser's body as the tunnel sends it, read in this process a chunk
  # at a time; the conn that read it is kept for the response.
  defp request_body(conn) do
    Stream.resource(
      fn -> {:more, conn} end,
      fn
        {:more, conn} ->
          case read_body(conn, length: @read_chunk, read_length: @read_chunk) do
            {:ok, data, conn} -> {chunks(data), {:done, conn}}
            {:more, data, conn} -> {chunks(data), {:more, conn}}
            {:error, _} -> raise ErrorAborted
          end

        {:done, conn} ->
          {:halt, {:done, conn}}
      end,
      fn {_, conn} -> Process.put(@conn_key, conn) end
    )
  end

  defp chunks(<<>>), do: []
  defp chunks(data), do: [data]

  defp respond(conn, status, response_headers, stream, origin) do
    headers = Headers.response_headers(response_headers, origin)

    # Media types are case-insensitive, and `response_headers/2` downcases
    # names but not values: `TEXT/HTML` is still HTML.
    html? =
      conn.method != "HEAD" and
        headers |> value("content-type") |> String.downcase() |> String.contains?("text/html") and
        value(headers, "content-encoding") == ""

    bodyless? = conn.method == "HEAD" or status in [204, 304]

    headers =
      cond do
        # A HEAD or 204/304 sends no body, so an upstream length still
        # describes what a GET would have returned and is worth keeping.
        bodyless? ->
          headers

        # Everything else is re-framed by `send_chunked/2`, so an upstream
        # length no longer describes what goes out. Bandit treats a declared
        # `content-length` as a promise and streams raw bytes with no framing,
        # so leaving one here desynchronises the connection: the browser stops
        # reading at the declared length and parses whatever the sandbox sent
        # after it as the next response. An `etag` survives a byte-for-byte
        # relay but not the HTML rewrite.
        html? ->
          Enum.reject(headers, fn {name, _} -> name in ["content-length", "etag"] end)

        true ->
          Enum.reject(headers, fn {name, _} -> name == "content-length" end)
      end

    conn = put_headers(conn, headers)

    if bodyless? do
      send_resp(conn, status, "")
    else
      conn
      |> send_chunked(status)
      |> stream_body(stream, if(html?, do: Html.new()))
    end
  end

  defp stream_body(conn, stream, html) do
    result =
      try do
        Enum.reduce_while(stream, {:ok, conn, html}, fn chunk, {:ok, conn, html} ->
          {out, html} = transform(html, chunk)

          case send_chunk(conn, out) do
            {:ok, conn} -> {:cont, {:ok, conn, html}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      rescue
        # The tunnel ended underneath the body; the client must not take a
        # short body for the whole one.
        _ -> {:error, :upstream}
      end

    with {:ok, conn, html} <- result,
         {:ok, conn} <- send_chunk(conn, if(html, do: Html.flush(html), else: [])),
         :open <- revoked_or_open() do
      conn
    else
      _ -> raise ErrorAborted
    end
  end

  # The app's headers replace the defaults Plug put on the conn, and a
  # repeated one (several `set-cookie`) is kept repeated.
  defp put_headers(conn, headers) do
    conn =
      headers
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reduce(conn, &delete_resp_header(&2, &1))

    prepend_resp_headers(conn, headers)
  end

  defp transform(nil, chunk), do: {chunk, nil}
  defp transform(html, chunk), do: Html.push(html, chunk)

  # An empty chunk ends a chunked response in Bandit; never send one.
  defp send_chunk(conn, out) do
    if IO.iodata_length(out) == 0, do: {:ok, conn}, else: chunk(conn, out)
  end

  defp revoked_or_open do
    receive do
      {:preview_gateway, :close} -> :revoked
    after
      0 -> :open
    end
  end

  # ── WebSocket upgrades ───────────────────────────────────────────────

  defp upgrade(conn, backend, cfg, row, host, origin) do
    if header(conn, "origin") != origin,
      do: raise(Error, status: 403, code: "origin", message: "Invalid WebSocket origin.")

    if String.starts_with?(conn.request_path, @control),
      do: raise(Error, status: 404, code: "preview", message: @unknown_control)

    grant = authorize!(conn, backend, cfg, row)
    destination!(backend, row.track_id)

    if row.state != :ready,
      do: raise(Error, status: 503, code: "starting", message: "Preview is not ready.")

    backend.touch(row.track_id)
    track = track!(backend, row.track_id)
    watch = watch!(backend, row, grant, track.project_id)

    tunnel =
      try do
        open_tunnel!(backend, row)
      rescue
        error in Error ->
          Watch.stop(watch)
          reraise error, __STACKTRACE__
      end

    tunnel_module = tunnel_module()

    headers =
      conn.req_headers
      |> Headers.upstream_headers(host, true)
      |> Enum.reject(fn {name, _} ->
        name in ~w(connection upgrade sec-websocket-extensions sec-websocket-key sec-websocket-version)
      end)

    case tunnel_http().upgrade(tunnel, target(conn), headers) do
      # `leftover` is whatever the app sent in the same packet as its 101:
      # the first bytes of the relayed stream, ahead of any tunnel message.
      {:ok, response_headers, leftover} ->
        conn =
          case value(response_headers, "sec-websocket-protocol") do
            "" -> conn
            protocol -> put_resp_header(conn, "sec-websocket-protocol", protocol)
          end

        state = %{tunnel: tunnel, tunnel_module: tunnel_module, watch: watch, leftover: leftover}

        WebSockAdapter.upgrade(conn, Relay, state,
          compress: false,
          max_frame_size: @max_frame,
          timeout: :infinity
        )

      {:error, _reason} ->
        tunnel_module.close(tunnel)
        Watch.stop(watch)
        raise Error, status: 502, code: "preview_unavailable", message: @generic
    end
  end

  defp refuse_upgrade(conn, %Error{status: status}) do
    conn |> put_resp_header("cache-control", "no-store") |> send_resp(status, "")
  end

  # ── replies ──────────────────────────────────────────────────────────

  # Bodies are generated gateway pages or escaped errors; preview app content
  # is deliberately served on its separate preview origin, never the app origin.
  # sobelow_skip ["XSS.SendResp"]
  defp reply(conn, status, body, type \\ "text/html; charset=utf-8") do
    conn
    |> put_resp_header("content-type", type)
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, body)
  end

  defp fail(conn, backend, %Error{status: status, message: message}) do
    reply(
      conn,
      status,
      ~s(<meta name="viewport" content="width=device-width,initial-scale=1"><p>#{escape(message)}</p>) <>
        ~s(<a href="#{escape(backend.public_url())}">Back to Ravix</a>)
    )
  end

  # The ticket lives in a fragment: absent from access logs and Referer.
  defp open_page do
    """
    <meta name="viewport" content="width=device-width,initial-scale=1"><p>Opening private preview…</p><script>
    const ticket=location.hash.slice(1);history.replaceState(null,'',location.pathname);
    fetch('#{@control}exchange',{method:'POST',headers:{'content-type':'text/plain'},body:ticket}).then(r=>{if(!r.ok)throw Error('This preview link expired. Open it again from Ravix.');location.replace('#{@control}start')}).catch(e=>document.querySelector('p').textContent=e.message);
    </script>
    """
  end

  defp start_page(back) do
    """
    <meta name="viewport" content="width=device-width,initial-scale=1"><h1>Live working copy</h1><p id="state">Starting preview…</p><pre id="logs"></pre><a href="#{escape(back)}">Back to track · send a correction</a><script>
    async function poll(){const r=await fetch('#{@control}status');if(!r.ok){document.querySelector('#state').textContent='Access ended. Return to the track.';return;}const s=await r.json();if(s.state==='ready'){location.replace('/');return;}document.querySelector('#state').textContent=s.error||'Starting preview…';document.querySelector('#logs').textContent=s.logs||'';if(s.state!=='failed')setTimeout(poll,1000)}poll();
    </script>
    """
  end

  defp activity_script(back) do
    "(()=>{const beat=()=>{if(document.visibilityState==='visible')fetch('#{@control}heartbeat',{method:'POST'}).catch(()=>{})};" <>
      "beat();setInterval(beat,30000);document.addEventListener('visibilitychange',beat);" <>
      "const host=document.createElement('div');const root=host.attachShadow({mode:'open'});const a=document.createElement('a');" <>
      "a.href=#{Jason.encode!(back)};a.textContent='Live working copy · Back to track';" <>
      "a.style.cssText='position:fixed;bottom:12px;right:12px;z-index:2147483647;background:#171717;color:white;padding:10px 14px;border-radius:8px;font:13px system-ui;text-decoration:none';" <>
      "root.append(a);document.body.append(host)})();"
  end

  # ── small helpers ────────────────────────────────────────────────────

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first("") |> String.downcase()

  defp value(headers, name) do
    Enum.find_value(headers, "", fn {key, value} -> String.downcase(key) == name && value end)
  end

  defp target(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp target(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  defp escape(text), do: text |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
end
