defmodule RavixWeb.PreviewGatewayTest do
  # No database: the backend is a fake over an Agent, one front serves the
  # module and each test owns its hostnames, sprite and upstream.
  use ExUnit.Case, async: true

  alias Ravix.Crypto
  alias Ravix.Hub
  alias Ravix.PreviewGatewayFake, as: Fake
  alias Ravix.PreviewGatewayFake.{Client, Store}
  alias RavixWeb.PreviewGateway.{Frame, Headers, Html}

  @script ~s(<script src="/__ravix/activity.js" defer></script>)

  setup_all do
    port = Fake.start_front!()

    on_exit(fn ->
      Application.delete_env(:ravix, :preview_backend)
      Application.delete_env(:ravix, :tunnel_module)
    end)

    %{port: port}
  end

  setup %{port: port}, do: %{f: Fake.fixture(port)}

  # ── the TypeScript gateway tests ─────────────────────────────────────

  test "auth precedes tunneling; gateway credentials and parent-domain cookies never reach apps",
       %{f: f} do
    assert get(f, "/", cookie: "").status == 401
    assert f.tunnels.() == 0

    res = get(f)
    assert res.status == 200
    assert res.body =~ "track app"
    assert res.body =~ "/__ravix/activity.js"
    assert_receive {:upstream, "GET", "/", "", headers}
    assert headers |> header("cookie") |> String.trim() == "app=okay"
    assert Enum.count(headers, fn {k, _} -> k == "cookie" end) == 1
    assert headers(res, "set-cookie") == ["app=1; Path=/"]
    assert f.tunnels.() == 1

    assert get(f, "/", host: f.other_host).status == 401
  end

  test "tickets are single-use and exchange only on their own origin", %{f: f} do
    ticket = ticket(f, "ticket", f.t1)

    exchange = fn origin ->
      get(f, "/__ravix/exchange", method: "POST", body: ticket, origin: origin)
    end

    assert exchange.("http://evil.test").status == 403
    accepted = exchange.(f.origin)
    assert accepted.status == 204
    [cookie] = headers(accepted, "set-cookie")

    assert cookie =~
             ~r/^ravix_preview_local=[A-Za-z0-9_-]+; Path=\/; HttpOnly; SameSite=Strict; Max-Age=43200$/

    assert exchange.(f.origin).status == 401

    # The new session opens the preview on its own.
    [pair | _] = String.split(cookie, ";")
    assert get(f, "/", cookie: pair).status == 200
  end

  test "HTTP streams deliver before completion and access revocation closes existing streams",
       %{f: f} do
    client = Client.stream(f.port, "GET", "/stream", [{"host", f.host}, {"cookie", f.cookie}])
    assert client.status == 200
    assert {:data, "first\n", client} = Client.next(client)

    Store.remove_member(f.t1, f.guest.id)
    Hub.publish(f.project, :tracks)

    assert {:error, _reason, _received, _client} = Client.drain(client)
    assert get(f).status == 401
  end

  test "WebSockets preserve text and binary frames and terminate on membership removal", %{f: f} do
    {:ok, ws} = Client.ws_connect(f.port, "/hmr", ws_headers(f))

    ws = Client.ws_send(ws, {:text, "hot reload"})
    assert {:ok, {:text, "hot reload"}, ws} = Client.ws_recv(ws)
    ws = Client.ws_send(ws, {:binary, <<0, 1, 2, 255>>})
    assert {:ok, {:binary, <<0, 1, 2, 255>>}, ws} = Client.ws_recv(ws)

    Store.remove_member(f.t1, f.guest.id)
    Hub.publish(f.project, :tracks)
    assert {:close, 1008, _reason, _ws} = Client.ws_await_close(ws)
  end

  test "expired tickets and cross-track exchanges cannot create a preview session", %{f: f} do
    wrong = ticket(f, "wrong-track", f.t1)

    assert get(f, "/__ravix/exchange",
             method: "POST",
             body: wrong,
             host: f.other_host,
             origin: "http://#{f.other_host}"
           ).status == 401

    expired = ticket(f, "expired", f.t1, Fake.now() - 1)

    assert get(f, "/__ravix/exchange", method: "POST", body: expired, origin: f.origin).status ==
             401

    assert f.tunnels.() == 0
  end

  test "removal permanently revokes sessions, even if the member is invited again", %{f: f} do
    Store.remove_member(f.t1, f.guest.id)
    Store.add_member(f.t1, f.guest.id)
    assert get(f).status == 401
    assert f.tunnels.() == 0
  end

  test "sign-out revokes preview sessions and WebSockets fail closed without auth or with a foreign origin",
       %{f: f} do
    assert {:error, 401} =
             Client.ws_connect(f.port, "/hmr", [{"host", f.host}, {"origin", f.origin}])

    assert {:error, 403} =
             Client.ws_connect(f.port, "/hmr", [
               {"host", f.host},
               {"cookie", f.cookie},
               {"origin", "http://other.preview.localhost"}
             ])

    Store.end_session(Crypto.sha256(f.app_session))
    assert get(f).status == 401
    assert f.tunnels.() == 0
  end

  test "HTTP request bodies are forwarded and cross-origin writes are rejected", %{f: f} do
    data = String.duplicate("payload ", 100_000)
    assert get(f, "/upload", method: "POST", body: data, origin: "http://evil").status == 403
    response = get(f, "/upload", method: "POST", body: data, origin: f.origin)
    assert response.status == 200
    assert response.body == data
  end

  test "a large body streams through whole", %{f: f} do
    response = get(f, "/flood")
    assert response.status == 200
    assert byte_size(response.body) == 128 * 65_536
  end

  # ── the TypeScript front tests ───────────────────────────────────────

  test "app hosts stay with the app; preview hosts reach the gateway with Host, cookies and Origin intact",
       %{f: f} do
    assert Client.request(f.port, "GET", "/", [{"host", "localhost:#{f.port}"}]).body == "app"

    res =
      get(f, "/hello?q=1",
        method: "POST",
        body: "payload",
        origin: f.origin,
        headers: [{"sec-fetch-site", "same-origin"}]
      )

    assert res.body == "hello #{f.host}"
    assert header(res.headers, "x-echo-host") == f.host
    assert_receive {:upstream, "POST", "/hello", "q=1", headers}
    assert header(headers, "host") == f.host
    assert headers |> header("cookie") |> String.trim() == "app=okay"
    assert header(headers, "origin") == f.origin
    assert header(headers, "sec-fetch-site") == "same-origin"
    assert header(headers, "accept-encoding") == "identity"
  end

  test "a Domain attribute is stripped however it is spelled, and the app's cookie never lands" do
    name = RavixWeb.Endpoint.session_cookie_name()

    strip = fn cookie ->
      [{"set-cookie", header}] =
        [{"set-cookie", cookie}]
        |> Headers.response_headers("https://t.preview.example")
        |> Enum.filter(fn {k, _} -> k == "set-cookie" end)

      header
    end

    # RFC 6265 trims whitespace around an attribute name, so a browser reads
    # every one of these as Domain and scopes the cookie to ravix.sh -- which
    # is a sibling of the app host, not a stranger to it.
    assert strip.("a=b; Domain=ravix.sh; Path=/") == "a=b; Path=/"
    assert strip.("a=b; Domain =ravix.sh; Path=/") == "a=b; Path=/"
    assert strip.("a=b; domain = ravix.sh; Path=/") == "a=b; Path=/"
    assert strip.("a=b; DOMAIN\t=ravix.sh") == "a=b"

    # An app running someone's branch must not be able to name the cookie the
    # Ravix session lives in, whatever it tries to scope it to.
    assert Headers.response_headers(
             [{"set-cookie", "#{name}=stolen; Domain =ravix.sh; Path=/"}],
             "https://t.preview.example"
           )
           |> Enum.filter(fn {k, _} -> k == "set-cookie" end) == []
  end

  test "an upstream content-length never survives the gateway's own re-framing", %{f: f} do
    # Every proxied body goes out through `send_chunked/2`, so the length the
    # upstream declared no longer describes what Ravix writes. Bandit treats a
    # declared content-length as a promise and streams raw bytes with no
    # framing, so forwarding a stale one desynchronises the connection: the
    # browser stops at the declared length and reads whatever the sandbox sent
    # after it as the start of the next response.
    gz = get(f, "/gzip")
    assert gz.status == 200
    assert headers(gz, "content-length") == []
    assert :zlib.gunzip(gz.body) == "inflated"

    html = get(f)
    assert html.status == 200
    assert headers(html, "content-length") == []
  end

  test "redirects, every Set-Cookie, encodings and streamed bodies pass through untouched", %{
    f: f
  } do
    redirect = get(f, "/redirect")
    assert redirect.status == 302
    assert header(redirect.headers, "location") == "/__ravix/start"

    cookies = get(f, "/cookies")
    assert cookies.status == 204
    assert headers(cookies, "set-cookie") == ["a=1; Path=/", "b=2; Path=/; HttpOnly"]

    gz = get(f, "/gzip")
    assert header(gz.headers, "content-encoding") == "gzip"
    assert :zlib.gunzip(gz.body) == "inflated"

    client = Client.stream(f.port, "GET", "/stream", [{"host", f.host}, {"cookie", f.cookie}])
    assert {:data, "first\n", client} = Client.next(client)
    assert {:data, "later\n", _client} = Client.next(client)
  end

  test "WebSockets relay both directions with their subprotocol, and a refused handshake is refused",
       %{f: f} do
    {:ok, ws} = Client.ws_connect(f.port, "/chat?x=1", ws_headers(f), ["vite-hmr", "other"])
    assert ws.protocol == "vite-hmr"
    assert {:ok, {:text, "welcome " <> host}, ws} = Client.ws_recv(ws)
    assert host == f.host

    ws = Client.ws_send(ws, {:text, "ping"})
    assert {:ok, {:text, "echo ping"}, ws} = Client.ws_recv(ws)
    ws = Client.ws_send(ws, {:binary, <<1, 2, 3>>})
    assert {:ok, {:binary, <<0xFF, 1, 2, 3>>}, ws} = Client.ws_recv(ws)
    # Bandit answers the browser's close itself, as `ws` did in the TypeScript.
    ws = Client.ws_send(ws, {:close, 1000, "bye"})
    assert {:close, 1000, _reason, _ws} = Client.ws_await_close(ws)

    assert_receive {:upstream, "GET", "/chat", "x=1", headers}
    assert header(headers, "host") == f.host
    assert header(headers, "origin") == f.origin
    assert header(headers, "sec-websocket-protocol") == "vite-hmr, other"
    assert header(headers, "sec-websocket-extensions") == ""

    assert {:error, 502} = Client.ws_connect(f.port, "/refuse", ws_headers(f))
  end

  # ── the checks the TypeScript made without a test of their own ──────

  test "browsers that mark a request cross-site or same-site are refused", %{f: f} do
    for site <- ["cross-site", "same-site"] do
      res = get(f, "/", headers: [{"sec-fetch-site", site}])
      assert res.status == 403
      assert res.body =~ "Open the preview directly."
    end

    assert get(f, "/", headers: [{"sec-fetch-site", "none"}]).status == 200
  end

  test "unknown hosts, closed tracks and unknown controls answer with the failure page", %{f: f} do
    missing = get(f, "/", host: "nope.preview.localhost:#{f.port}")
    assert missing.status == 404
    assert missing.body =~ "Preview not found."
    assert missing.body =~ ~s(<a href="http://localhost:5183">Back to Ravix</a>)
    assert header(missing.headers, "cache-control") == "no-store"
    assert header(missing.headers, "x-content-type-options") == "nosniff"

    assert get(f, "/__ravix/nope").status == 404
    assert get(f, "/__ravix/nope").body =~ "Unknown preview control."
    assert {:error, 404} = Client.ws_connect(f.port, "/__ravix/hmr", ws_headers(f))

    Store.update_track(f.t1, &%{&1 | closed_at: DateTime.utc_now()})
    closed = get(f)
    assert closed.status == 409
    assert closed.body =~ "closed or being retired"
    assert f.tunnels.() == 0
  end

  test "a preview that is not ready sends the browser to the starting page", %{f: f} do
    Store.update_row(f.t1, &%{&1 | state: :stopped})

    redirect = get(f)
    assert redirect.status == 302
    assert header(redirect.headers, "location") == "/__ravix/start"
    assert header(redirect.headers, "cache-control") == "no-store"

    start = get(f, "/__ravix/start")
    assert start.status == 200
    assert start.body =~ "Live working copy"
    assert start.body =~ ~s(href="http://localhost:5183/p/#{f.project}/t/#{f.t1}")
    eventually(fn -> :start_service in Store.calls(f.t1) end)
    assert :touch in Store.calls(f.t1)

    status = get(f, "/__ravix/status")
    assert header(status.headers, "content-type") == "application/json"
    assert Jason.decode!(status.body)["state"] == "stopped"
    assert f.tunnels.() == 0
  end

  test "heartbeats extend the lease only while the preview is wanted", %{f: f} do
    assert get(f, "/__ravix/heartbeat", method: "POST", origin: f.origin).status == 204
    assert :touch in Store.calls(f.t1)
    assert get(f, "/__ravix/heartbeat", method: "POST", origin: "http://evil").status == 403

    Store.update_row(f.t1, &%{&1 | desired: :stopped})
    assert get(f, "/__ravix/heartbeat", method: "POST", origin: f.origin).status == 409

    js = get(f, "/__ravix/activity.js")
    assert js.status == 200
    assert header(js.headers, "content-type") == "application/javascript; charset=utf-8"
    assert js.body =~ ~s|fetch('/__ravix/heartbeat',{method:'POST'})|
    assert js.body =~ ~s(a.href="http://localhost:5183/p/#{f.project}/t/#{f.t1}")
  end

  test "the open page carries the exchange without the ticket ever leaving the fragment", %{f: f} do
    res = get(f, "/__ravix/open", cookie: "")
    assert res.status == 200
    assert res.body =~ "location.hash.slice(1)"
    assert res.body =~ "fetch('/__ravix/exchange'"
    assert res.body =~ "location.replace('/__ravix/start')"

    assert get(f, "/__ravix/exchange",
             method: "POST",
             body: String.duplicate("x", 200),
             origin: f.origin
           ).status == 400
  end

  test "response headers: hop-by-hop and site-clearing headers go, caching is off, redirects stay on the preview",
       %{f: f} do
    hop = get(f, "/hop")
    assert hop.status == 200
    assert hop.body == "hop"
    assert header(hop.headers, "x-drop-me") == ""
    assert header(hop.headers, "clear-site-data") == ""
    assert header(hop.headers, "alt-svc") == ""
    assert header(hop.headers, "cache-control") == "no-store"
    assert header(hop.headers, "referrer-policy") == "no-referrer"
    assert header(hop.headers, "etag") == ~s("abc")

    local = get(f, "/redirect-local")
    assert local.status == 302
    assert header(local.headers, "location") == "#{f.origin}/next?x=1#frag"
  end

  test "the activity script is injected once, into HTML only, and never into encoded bodies", %{
    f: f
  } do
    page = get(f)

    assert page.body ==
             ~s(<!DOCTYPE html><html><head><title>App</title>#{@script}</head><body>track app</body></html>)

    assert header(page.headers, "content-length") == ""
    assert header(page.headers, "etag") == ""

    headless = get(f, "/headless")
    assert headless.body == "<p>no head here</p>" <> @script

    encoded = get(f, "/gzip-html")
    assert header(encoded.headers, "content-encoding") == "gzip"
    refute :zlib.gunzip(encoded.body) =~ "activity.js"

    plain = get(f, "/hello")
    refute plain.body =~ "activity.js"

    head = get(f, "/", method: "HEAD")
    assert head.status == 200
    assert head.body == ""
  end

  test "a rebuilt preview (new generation) closes streams opened on the old one", %{f: f} do
    client = Client.stream(f.port, "GET", "/stream", [{"host", f.host}, {"cookie", f.cookie}])
    assert {:data, "first\n", client} = Client.next(client)

    Store.update_row(f.t1, &%{&1 | generation: 1})
    Hub.publish(f.project, :tracks)
    assert {:error, _reason, _received, _client} = Client.drain(client)
  end

  test "revocation is noticed without a hub event, on the timer", %{f: f} do
    {:ok, ws} = Client.ws_connect(f.port, "/hmr", ws_headers(f))
    Store.end_session(Crypto.sha256(f.app_session))
    assert {:close, 1008, _reason, _ws} = Client.ws_await_close(ws, 5_000)
  end

  test "a sprite that does not answer is a 502 with the way back", %{f: f} do
    Store.update_row(f.t1, &%{&1 | port: closed_port()})
    res = get(f)
    assert res.status == 502
    assert res.body =~ "The preview did not answer."
    assert res.body =~ "Back to Ravix"
    assert {:error, 502} = Client.ws_connect(f.port, "/hmr", ws_headers(f))
  end

  test "the sprite's WebSocket closing closes the browser's", %{f: f} do
    {:ok, ws} = Client.ws_connect(f.port, "/hmr", ws_headers(f))
    upstream = f.app_port
    Store.update_row(f.t1, &%{&1 | port: upstream})
    # The upstream is per test; stopping it drops every socket it holds.
    # `stop_supervised/1` answers `{:error, :not_found}` when the child is
    # already on its way down, which it intermittently is by the time this
    # line runs -- and matching only `:ok` turned that into a MatchError
    # rather than the outcome this test is actually about, which is the next
    # assertion.
    assert stop_supervised({:preview_gateway_upstream, String.replace(f.row.hostname, "t-", "")}) in [
             :ok,
             {:error, :not_found}
           ]

    # Bandit's shutdown sends the app's sockets a 1000, relayed as it came.
    assert {:close, 1000, _reason, _ws} = Client.ws_await_close(ws)
  end

  # ── the pieces on their own ──────────────────────────────────────────

  describe "Headers" do
    test "upstream: hop-by-hop, forwarding and credentials go; cookies are scrubbed; host is the preview" do
      headers = [
        {"connection", "keep-alive, x-custom"},
        {"x-custom", "1"},
        {"keep-alive", "timeout=5"},
        {"authorization", "Bearer x"},
        {"x-forwarded-for", "1.2.3.4"},
        {"forwarded", "for=1.2.3.4"},
        {"accept-encoding", "gzip"},
        {"cookie", "__Host-ravix_preview=a; #{RavixWeb.Endpoint.session_cookie_name()}=b"},
        {"cookie", "app=1"},
        {"host", "wrong"},
        {"user-agent", "test"}
      ]

      assert Headers.upstream_headers(headers, "t.preview.example") == [
               {"user-agent", "test"},
               {"cookie", " app=1"},
               {"host", "t.preview.example"},
               {"accept-encoding", "identity"}
             ]

      assert {"upgrade", "websocket"} in Headers.upstream_headers([], "h", :upgrade)

      refute Enum.any?(
               Headers.upstream_headers(
                 [{"cookie", "#{RavixWeb.Endpoint.session_cookie_name()}=x"}],
                 "h"
               ),
               &(elem(&1, 0) == "cookie")
             )
    end

    test "response: gateway cookies cannot be set, domains are stripped, localhost redirects are rewritten" do
      headers = [
        {"Set-Cookie", "ravix_preview_local=evil; Path=/"},
        {"set-cookie", "a=1; Domain=.example.com; Path=/; domain=x"},
        {"location", "http://127.0.0.1:3000/x?y=1"},
        {"cache-control", "public"},
        {"transfer-encoding", "chunked"},
        {"content-type", "text/html"}
      ]

      assert Headers.response_headers(headers, "https://t.preview.example") == [
               {"set-cookie", "a=1; Path=/"},
               {"location", "https://t.preview.example/x?y=1"},
               {"content-type", "text/html"},
               {"referrer-policy", "no-referrer"},
               {"cache-control", "no-store"}
             ]

      assert Headers.response_headers([{"location", "https://example.com/"}], "o")
             |> header("location") ==
               "https://example.com/"
    end

    test "cookie lookup" do
      headers = [{"cookie", "a=1; ravix_preview_local=tok=en; b=2"}]
      assert Headers.cookie(headers, "ravix_preview_local") == "tok=en"
      assert Headers.cookie(headers, "missing") == ""
      assert Headers.cookie_name(:http) == "ravix_preview_local"
      assert Headers.cookie_name(:https) == "__Host-ravix_preview"
    end
  end

  describe "Html" do
    test "injects before </head> even when the tag straddles chunks" do
      html = Html.new()
      {out1, html} = Html.push(html, "<html><HEAD><title>x</title></HE")
      assert IO.iodata_to_binary(out1) == ""
      {out2, html} = Html.push(html, "AD><body>")
      assert IO.iodata_to_binary(out2) == "<html><HEAD><title>x</title>#{@script}</HEAD><body>"
      {out3, html} = Html.push(html, "</body>")
      assert IO.iodata_to_binary(out3) == "</body>"
      assert IO.iodata_to_binary(Html.flush(html)) == ""
    end

    test "gives up waiting after 32 KiB and appends at the end otherwise" do
      big = String.duplicate("a", 40_000)
      {out, html} = Html.push(Html.new(), big)
      assert IO.iodata_to_binary(out) == big <> @script
      {out, _} = Html.push(html, "</head>")
      assert IO.iodata_to_binary(out) == "</head>"

      {out, html} = Html.push(Html.new(), "no head")
      assert IO.iodata_to_binary(out) == ""
      assert IO.iodata_to_binary(Html.flush(html)) == "no head" <> @script
    end
  end

  describe "Frame" do
    test "client frames are masked and server frames, fragmented or not, decode in order" do
      encoded = IO.iodata_to_binary(Frame.encode({:text, "hi"}))
      assert <<0x81, 0x82, _key::32, _masked::16>> = encoded

      server = <<0x01, 3, "abc", 0x89, 1, "p", 0x80, 2, "de", 0x82, 1, 0xFF, 0x88, 2, 1000::16>>
      {:ok, frames, decoder} = Frame.decode(Frame.new(), binary_part(server, 0, 7))
      assert frames == []
      {:ok, frames, _} = Frame.decode(decoder, binary_part(server, 7, byte_size(server) - 7))
      assert frames == [{:ping, "p"}, {:text, "abcde"}, {:binary, <<0xFF>>}, {:close, 1000, ""}]
    end

    test "oversized and masked server frames are errors" do
      assert {:error, :max_payload} = Frame.decode(Frame.new(), <<0x82, 127, 2_000_000::64>>)

      assert {:error, :masked_server_frame} =
               Frame.decode(Frame.new(), <<0x81, 0x81, 1, 2, 3, 4, 5>>)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp get(f, path \\ "/", opts \\ []) do
    headers =
      [{"host", Keyword.get(opts, :host, f.host)}] ++
        cookie_header(Keyword.get(opts, :cookie, f.cookie)) ++
        origin_header(opts[:origin]) ++
        Keyword.get(opts, :headers, [])

    Client.request(f.port, Keyword.get(opts, :method, "GET"), path, headers, opts[:body])
  end

  defp cookie_header(""), do: []
  defp cookie_header(cookie), do: [{"cookie", cookie}]
  defp origin_header(nil), do: []
  defp origin_header(origin), do: [{"origin", origin}]

  defp ws_headers(f), do: [{"host", f.host}, {"origin", f.origin}, {"cookie", f.cookie}]

  defp ticket(f, secret, track_id, expires \\ Fake.now() + 60_000) do
    value = "#{secret}-#{f.row.hostname}"

    Store.put_grant(%{
      hash: Crypto.sha256(value),
      track_id: track_id,
      session_hash: Crypto.sha256(f.app_session),
      expires: expires,
      kind: :ticket
    })

    value
  end

  defp header(headers, name),
    do: Enum.find_value(headers, "", fn {k, v} -> String.downcase(k) == name && v end)

  defp headers(%{headers: headers}, name), do: for({k, v} <- headers, k == name, do: v)

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
