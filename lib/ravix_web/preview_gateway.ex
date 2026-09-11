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
    @moduledoc """
    A refusal with the status the browser should see.

    It was `HttpError` in the TypeScript, raised from wherever the refusal
    was decided and caught once at the top; six `!` functions here did the
    same, which made the set of ways a request could end something you
    found by reading all of them. Now every step answers `{:error, %Error{}}`
    and `handle/4` matches on it, so the paths are in the `with` chains
    that take them.

    It stays an exception because `Plug.Exception` gives it a status, and
    because `ErrorAborted` --- the one refusal that genuinely has to unwind,
    since it happens after the headers are out and there is no conn left to
    return --- is its neighbour.
    """
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
  @open @control <> "open"
  @exchange @control <> "exchange"
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
  @closed_track "This track is closed or being retired."
  @sign_in "Open this preview from your signed-in Ravix track."

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

    result =
      with {:ok, site} <- resolve(backend, cfg, name) do
        if websocket?, do: upgrade(conn, site), else: request(conn, site)
      end

    case result do
      %Plug.Conn{} = conn -> conn
      {:error, %Error{} = error} when websocket? -> refuse_upgrade(conn, error)
      {:error, %Error{} = error} -> fail(conn, backend, error)
    end
  end

  # ── resolution and authorization ─────────────────────────────────────

  # The whole of what a preview request is served against, settled once and
  # then constant. It used to be six positional arguments threaded through
  # `request`, `authorized`, `proxy`, `exchange` and `upgrade`; `@enforce_keys`
  # is what stops a seventh being forgotten at one of the call sites.
  defmodule Site do
    @moduledoc false
    @enforce_keys [:backend, :cfg, :row, :host, :origin]
    defstruct @enforce_keys
  end

  defp resolve(backend, cfg, name) do
    with {:ok, row} <- resolve_host(backend, name) do
      host = "#{row.hostname}.#{cfg.domain}#{cfg.public_port}"

      {:ok,
       %Site{
         backend: backend,
         cfg: cfg,
         row: row,
         host: host,
         origin: "#{cfg.protocol}://#{host}"
       }}
    end
  end

  defp resolve_host(backend, name) do
    with {:ok, row} <- found(backend.resolve_host(name)),
         :ok <- open(backend, row.track_id) do
      {:ok, row}
    end
  end

  defp found({:ok, row}), do: {:ok, row}
  defp found(:error), do: refuse(404, "preview", @not_found)

  defp open(backend, track_id) do
    case backend.assert_open(track_id) do
      :ok -> :ok
      {:error, reason} -> refusal(reason, 409, "closed_track", @closed_track)
    end
  end

  defp authorize(conn, %Site{} = site) do
    hash =
      conn.req_headers
      |> Headers.cookie(Headers.cookie_name(site.cfg.protocol))
      |> Crypto.sha256()

    grant = site.backend.get_grant(hash, site.row.track_id, :session, :peek)

    if grant && site.backend.allowed?(site.row, grant),
      do: {:ok, grant},
      else: refuse(401, "preview_signin", @sign_in)
  end

  defp track(%Site{} = site) do
    case site.backend.track(site.row.track_id) do
      nil -> refuse(404, "preview", @not_found)
      track -> {:ok, track}
    end
  end

  defp destination(%Site{} = site) do
    case site.backend.destination(site.row.track_id) do
      {:ok, _} -> :ok
      {:error, reason} -> refusal(reason, 502, "preview_unavailable", @generic)
    end
  end

  defp watch(%Site{} = site, grant, project_id) do
    case Watch.start(site.backend, site.row, grant, project_id) do
      {:ok, watch} -> {:ok, watch}
      :revoked -> refuse(401, "preview_signin", @sign_in)
    end
  end

  defp open_tunnel(%Site{} = site) do
    with %Ravix.Config.Sprites{} = sprites <- site.backend.sprites_config(),
         {:ok, tunnel} <- tunnel_module().open(sprites, site.row.sprite, site.row.port, []) do
      {:ok, tunnel}
    else
      _ -> refuse(502, "preview_unavailable", @generic)
    end
  end

  # `refuse/3` is a refusal the gateway decided on; `refusal/4` is one a
  # backend handed back, whose own status and sentence win when it has them
  # (`assert_open/1` and `destination/1` answer with the words the person
  # should read) and which otherwise falls back to the generic pair.
  defp refuse(status, code, message),
    do: {:error, %Error{status: status, code: code, message: message}}

  defp refusal(%{status: status, message: message}, _status, code, _message)
       when is_integer(status),
       do: {:error, %Error{status: status, code: code, message: message}}

  defp refusal(_reason, status, code, message), do: refuse(status, code, message)

  # ── plain requests ───────────────────────────────────────────────────

  defp request(conn, %Site{} = site) do
    case {conn.request_path, conn.method} do
      {@open, "GET"} -> reply(conn, 200, open_page())
      {@exchange, "POST"} -> exchange(conn, site)
      _ -> authorized(conn, site)
    end
  end

  defp exchange(conn, %Site{} = site) do
    with :ok <- same_origin_exactly(conn, site.origin, "Open previews from their own host."),
         {:ok, body, conn} <- read_ticket(conn),
         {:ok, ticket} <- claim_ticket(site, body),
         {:ok, token} <- mint_session(site, ticket) do
      secure = if site.cfg.protocol == :https, do: "; Secure", else: ""

      conn
      |> put_resp_header(
        "set-cookie",
        "#{Headers.cookie_name(site.cfg.protocol)}=#{token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200#{secure}"
      )
      |> reply(204, "")
    end
  end

  # The ticket is single-use, so reading it spends it. Everything that can
  # make it worthless -- no such ticket, a Ravix session that has since
  # ended, a track the person no longer reaches or that has closed --
  # answers with one sentence, because telling them apart would tell an
  # unauthenticated caller which.
  defp claim_ticket(%Site{} = site, body) do
    ticket = site.backend.get_grant(Crypto.sha256(body), site.row.track_id, :ticket, :consume)
    user = ticket && site.backend.session_user(ticket.session_hash)

    if user &&
         match?({:ok, %{closed_at: nil}}, site.backend.track_access(user, site.row.track_id)),
       do: {:ok, ticket},
       else: refuse(401, "ticket", "This preview link expired. Open it again from Ravix.")
  end

  defp mint_session(%Site{} = site, ticket) do
    token = Crypto.random_token()

    session = %{
      hash: Crypto.sha256(token),
      track_id: ticket.track_id,
      session_hash: ticket.session_hash,
      expires: System.system_time(:millisecond) + @session_ttl_ms,
      kind: :session
    }

    case site.backend.grant_session(session) do
      :ok -> {:ok, token}
      {:error, _} -> refuse(502, "preview_unavailable", @generic)
    end
  end

  defp read_ticket(conn) do
    case read_body(conn, length: 128, read_length: 128) do
      {:ok, body, conn} when byte_size(body) <= 128 -> {:ok, body, conn}
      _ -> refuse(400, "ticket", "Invalid ticket.")
    end
  end

  defp authorized(conn, %Site{} = site) do
    with {:ok, grant} <- authorize(conn, site),
         :ok <- same_origin(conn, site.origin),
         {:ok, track} <- track(site) do
      back = "#{site.backend.public_url()}/p/#{track.project_id}/t/#{track.id}"

      cond do
        String.starts_with?(conn.request_path, @control) ->
          control(conn, site, back)

        site.row.state != :ready ->
          conn
          |> put_resp_header("location", @start)
          |> put_resp_header("cache-control", "no-store")
          |> send_resp(302, "")

        true ->
          proxy(conn, site, grant, track)
      end
    end
  end

  # Same-origin writes and upgrades also prevent cross-track CSRF when
  # wildcard hosts happen to share a registrable domain.
  defp same_origin(conn, origin) do
    cond do
      conn.method not in ["GET", "HEAD"] and header(conn, "origin") != origin ->
        refuse(403, "origin", "Cross-origin preview writes are not allowed.")

      header(conn, "sec-fetch-site") in ["cross-site", "same-site"] ->
        refuse(403, "origin", "Open the preview directly.")

      true ->
        :ok
    end
  end

  defp same_origin_exactly(conn, origin, message) do
    if header(conn, "origin") == origin, do: :ok, else: refuse(403, "origin", message)
  end

  defp control(conn, %Site{} = site, back) do
    case {conn.request_path, conn.method} do
      {@start, _} ->
        site.backend.touch(site.row.track_id)
        if site.row.state == :stopped, do: start_service(site)
        reply(conn, 200, start_page(back))

      {@status, _} ->
        reply(conn, 200, Jason.encode!(site.backend.info(site.row.track_id)), "application/json")

      {@heartbeat, "POST"} ->
        if site.row.desired == :running do
          site.backend.touch(site.row.track_id)
          reply(conn, 204, "")
        else
          refuse(409, "stopped", "Preview stopped. Open it from the track again.")
        end

      {@activity, _} ->
        reply(conn, 200, activity_script(back), "application/javascript; charset=utf-8")

      _ ->
        refuse(404, "preview", @unknown_control)
    end
  end

  # Fire and forget, as the TypeScript's `void manager.startService(...)`.
  defp start_service(%Site{} = site) do
    Task.Supervisor.start_child(Ravix.TaskSupervisor, fn ->
      site.backend.start_service(site.row.track_id)
    end)
  end

  # ── the reverse proxy ────────────────────────────────────────────────

  defp proxy(conn, %Site{} = site, grant, track) do
    with :ok <- destination(site),
         _ = site.backend.touch(site.row.track_id),
         {:ok, watch} <- watch(site, grant, track.project_id) do
      try do
        with {:ok, tunnel} <- open_tunnel(site) do
          tunnel_module = tunnel_module()
          Watch.attach(watch, fn -> tunnel_module.close(tunnel) end)

          try do
            relay(conn, site, tunnel)
          after
            tunnel_module.close(tunnel)
          end
        end
      after
        Watch.stop(watch)
      end
    end
  end

  defp relay(conn, %Site{} = site, tunnel) do
    headers = Headers.upstream_headers(conn.req_headers, site.host)
    body = if conn.method in ["GET", "HEAD"], do: nil, else: request_body(conn)

    response =
      tunnel_http().request(tunnel, conn.method, target(conn), headers, body,
        body_timeout: @body_timeout
      )

    conn = Process.delete(@conn_key) || conn

    case response do
      {:ok, status, response_headers, stream} ->
        respond(conn, status, response_headers, stream, site.origin)

      {:error, _reason} ->
        refuse(502, "preview_unavailable", @generic)
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

  defp upgrade(conn, %Site{} = site) do
    with :ok <- same_origin_exactly(conn, site.origin, "Invalid WebSocket origin."),
         :ok <- not_control(conn),
         {:ok, grant} <- authorize(conn, site),
         :ok <- destination(site),
         :ok <- ready(site),
         _ = site.backend.touch(site.row.track_id),
         {:ok, track} <- track(site),
         {:ok, watch} <- watch(site, grant, track.project_id) do
      case open_tunnel(site) do
        {:ok, tunnel} -> relay_socket(conn, site, tunnel, watch)
        {:error, _} = refusal -> stop_watch(watch, refusal)
      end
    end
  end

  defp not_control(conn) do
    if String.starts_with?(conn.request_path, @control),
      do: refuse(404, "preview", @unknown_control),
      else: :ok
  end

  defp ready(%Site{row: %{state: :ready}}), do: :ok
  defp ready(%Site{}), do: refuse(503, "starting", "Preview is not ready.")

  defp relay_socket(conn, %Site{} = site, tunnel, watch) do
    tunnel_module = tunnel_module()

    headers =
      conn.req_headers
      |> Headers.upstream_headers(site.host, :upgrade)
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
        stop_watch(watch, refuse(502, "preview_unavailable", @generic))
    end
  end

  # An upgrade that gets this far owns the watch, because a successful one
  # hands it to `Relay` to stop. So every way out from here that is not a
  # live socket has to stop it, which is the whole of what the old
  # `rescue ... reraise` around `open_tunnel!/2` was for.
  defp stop_watch(watch, refusal) do
    Watch.stop(watch)
    refusal
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
