defmodule Ravix.Sprites.Tunnel.HTTP do
  @moduledoc """
  A minimal HTTP/1.1 client over a `Ravix.Sprites.Tunnel`.

  The preview gateway is a reverse proxy whose upstream is a port inside a
  sprite, reachable only through the tunnel, so no HTTP client that opens
  its own sockets can be pointed at it. The TypeScript handed undici a
  custom stream; here the client is small enough to write: one request per
  tunnel, the head and body written with `Tunnel.send_data/2`, the response
  parsed out of the `{:tunnel, _, {:data, _}}` messages the tunnel delivers.
  Every function must therefore be called in the process that opened the
  tunnel, and the body stream `request/6` returns must be consumed there too.

  Hop-by-hop headers are not the caller's business. Whatever the caller
  passes is stripped of `connection`, `transfer-encoding`, `upgrade` and
  their relatives (and of anything the caller's own `connection` header
  names), and the client writes the ones this connection needs: a request
  is `connection: close` because the tunnel serves exactly one, a body of
  known size gets a `content-length`, a streamed body without one is sent
  chunked, and an upgrade carries `connection: Upgrade`. A `content-length`
  the caller supplies is kept and trusted, which is how a proxied request
  body of known size goes through without re-framing.

  The response body comes back as a stream that decodes chunked and
  content-length bodies and reads a length-less body until the tunnel
  closes. A body that ends early, because the tunnel closed or failed,
  raises `Ravix.Sprites.Error` from the stream, since a stream has no other
  way to say so. The tunnel is left open when the body ends; closing it is
  the caller's job, the way `client.destroy()` was.
  """

  alias Ravix.Sprites.Error
  alias Ravix.Sprites.Tunnel

  @hop ~w(connection keep-alive proxy-authenticate proxy-authorization proxy-connection te trailer transfer-encoding upgrade)
  @headers_timeout 30_000
  @max_head 64 * 1024

  @typedoc "Header names are lowercase on the way out; on the way in they are lowercased."
  @type headers :: [{String.t(), String.t()}]

  @typedoc "No body, a body of known size, or an enumerable of chunks (iodata)."
  @type body :: nil | binary() | Enumerable.t()

  @typedoc """
    * `:headers_timeout` - how long to wait for the response head (default 30s)
    * `:body_timeout` - how long the body stream waits between chunks (default `:infinity`)
  """
  @type option :: {:headers_timeout, timeout()} | {:body_timeout, timeout()}

  @doc """
  Send one request and read the response head.

  Returns the status, the response headers (names lowercased, in order) and
  a lazy body stream of binaries. A `HEAD` request, a 1xx, 204 or 304 status
  yield an empty stream; a 100 Continue on the way is skipped.
  """
  @spec request(Tunnel.t(), String.t(), String.t(), headers(), body(), [option()]) ::
          {:ok, pos_integer(), headers(), Enumerable.t()} | {:error, Error.t()}
  def request(tunnel, method, path, headers, body, opts \\ []) do
    method = String.upcase(method)
    {headers, body} = framing(method, request_headers(headers), body)
    head = head(method, path, headers ++ [{"connection", "close"}])

    with :ok <- write(tunnel, head, body),
         {:ok, status, response_headers, rest} <- read_head(tunnel, opts) do
      mode = body_mode(method, status, response_headers)
      timeout = Keyword.get(opts, :body_timeout, :infinity)
      {:ok, status, response_headers, body_stream(tunnel, mode, rest, timeout)}
    end
  end

  @doc """
  Ask the upstream to switch protocols.

  Sends `GET path` with the caller's headers plus `connection: Upgrade` and
  `upgrade: websocket`. A caller's `sec-websocket-key` and
  `sec-websocket-version` are kept (in the gateway they are the browser's);
  when absent, a fresh key and version 13 are added. The accept key is not
  checked here, since the browser checks the one the gateway minted for it,
  and the upstream is a process on the same machine. On a 101 the response headers come back
  with whatever bytes followed the head, which are the first bytes of the
  raw duplex the tunnel now is; deliver those before reading further
  `{:tunnel, _, {:data, _}}` messages. Any other status is returned with
  its headers so the caller can decide what to tell the browser.
  """
  @spec upgrade(Tunnel.t(), String.t(), headers(), [option()]) ::
          {:ok, headers(), binary()}
          | {:error, {:status, pos_integer(), headers()} | Error.t()}
  def upgrade(tunnel, path, headers, opts \\ []) do
    headers =
      headers
      |> request_headers()
      |> put_new_header("sec-websocket-key", fn ->
        Base.encode64(:crypto.strong_rand_bytes(16))
      end)
      |> put_new_header("sec-websocket-version", fn -> "13" end)
      |> Kernel.++([{"connection", "Upgrade"}, {"upgrade", "websocket"}])

    with :ok <- write(tunnel, head("GET", path, headers), nil),
         {:ok, status, response_headers, rest} <- read_head(tunnel, opts) do
      if status == 101,
        do: {:ok, response_headers, rest},
        else: {:error, {:status, status, response_headers}}
    end
  end

  # ── writing ──────────────────────────────────────────────────────────

  # The caller's headers, lowercased, without hop-by-hop ones, with a host.
  defp request_headers(headers) do
    headers = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)

    named_hops =
      headers
      |> Enum.filter(fn {name, _value} -> name == "connection" end)
      |> Enum.flat_map(fn {_name, value} -> String.split(value, ",") end)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    kept = Enum.reject(headers, fn {name, _value} -> name in @hop or name in named_hops end)

    if List.keymember?(kept, "host", 0), do: kept, else: [{"host", "127.0.0.1"} | kept]
  end

  defp put_new_header(headers, name, value) do
    if List.keymember?(headers, name, 0), do: headers, else: headers ++ [{name, value.()}]
  end

  # How the body goes on the wire: a known size, chunked, or nothing.
  defp framing(method, headers, nil) do
    if method in ["POST", "PUT", "PATCH"] and not List.keymember?(headers, "content-length", 0),
      do: {headers ++ [{"content-length", "0"}], nil},
      else: {headers, nil}
  end

  defp framing(_method, headers, body) when is_binary(body) do
    if List.keymember?(headers, "content-length", 0),
      do: {headers, body},
      else: {headers ++ [{"content-length", Integer.to_string(byte_size(body))}], body}
  end

  defp framing(_method, headers, stream) do
    if List.keymember?(headers, "content-length", 0),
      do: {headers, {:raw, stream}},
      else: {headers ++ [{"transfer-encoding", "chunked"}], {:chunked, stream}}
  end

  defp head(method, path, headers) do
    [
      method,
      " ",
      path,
      " HTTP/1.1\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n"
    ]
  end

  defp write(tunnel, head, nil), do: send_bytes(tunnel, head)
  defp write(tunnel, head, body) when is_binary(body), do: send_bytes(tunnel, [head, body])

  defp write(tunnel, head, {:raw, stream}) do
    with :ok <- send_bytes(tunnel, head), do: stream_body(tunnel, stream, & &1)
  end

  defp write(tunnel, head, {:chunked, stream}) do
    encode = &[Integer.to_string(IO.iodata_length(&1), 16), "\r\n", &1, "\r\n"]

    with :ok <- send_bytes(tunnel, head),
         :ok <- stream_body(tunnel, stream, encode) do
      send_bytes(tunnel, "0\r\n\r\n")
    end
  end

  # An empty chunk would read as the terminator, so empty pieces are skipped.
  defp stream_body(tunnel, stream, encode) do
    stream
    |> Stream.reject(&(IO.iodata_length(&1) == 0))
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case send_bytes(tunnel, encode.(chunk)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp send_bytes(tunnel, data) do
    case Tunnel.send_data(tunnel, data) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.new(502, "The preview connection failed: #{format(reason)}")}
    end
  end

  # ── the response head ────────────────────────────────────────────────

  defp read_head(tunnel, opts) do
    timeout = Keyword.get(opts, :headers_timeout, @headers_timeout)
    deadline = deadline(timeout)
    parse_head(tunnel, <<>>, deadline)
  end

  defp parse_head(_tunnel, buffer, _deadline) when byte_size(buffer) > @max_head,
    do: {:error, Error.new(502, "The preview's response head is too large.")}

  defp parse_head(tunnel, buffer, deadline) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:ok, {:http_response, _version, status, _reason}, rest} ->
        case parse_headers(rest, []) do
          {:ok, _headers, rest} when status in 100..199 and status != 101 ->
            parse_head(tunnel, rest, deadline)

          {:ok, headers, rest} ->
            {:ok, status, headers, rest}

          :more ->
            more_head(tunnel, buffer, deadline)

          :error ->
            {:error, Error.new(502, "The preview answered with something other than HTTP.")}
        end

      {:more, _length} ->
        more_head(tunnel, buffer, deadline)

      _error ->
        {:error, Error.new(502, "The preview answered with something other than HTTP.")}
    end
  end

  defp parse_headers(buffer, acc) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:ok, {:http_header, _n, name, _reserved, value}, rest} ->
        parse_headers(rest, [{header_name(name), String.trim(value)} | acc])

      {:ok, :http_eoh, rest} ->
        {:ok, Enum.reverse(acc), rest}

      {:more, _length} ->
        :more

      _error ->
        :error
    end
  end

  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(name), do: String.downcase(name)

  defp more_head(tunnel, buffer, deadline) do
    receive do
      {:tunnel, ^tunnel, {:data, data}} ->
        parse_head(tunnel, buffer <> data, deadline)

      {:tunnel, ^tunnel, :closed} ->
        {:error, Error.new(502, "The preview closed the connection before answering.")}

      {:tunnel, ^tunnel, {:error, reason}} ->
        {:error, Error.new(502, "The preview connection failed: #{format(reason)}")}
    after
      remaining(deadline) ->
        {:error, Error.new(504, "The preview did not answer in time.")}
    end
  end

  # ── the response body ────────────────────────────────────────────────

  # RFC 7230 3.3.3, in order: no body for HEAD and the bodiless statuses,
  # chunked wins over content-length, and otherwise read until close.
  defp body_mode("HEAD", _status, _headers), do: :none

  defp body_mode(_method, status, _headers) when status in 100..199 or status in [204, 304],
    do: :none

  defp body_mode(_method, _status, headers) do
    transfer_encoding = header(headers, "transfer-encoding") || ""

    cond do
      String.contains?(String.downcase(transfer_encoding), "chunked") ->
        {:chunked, :size}

      length = content_length(headers) ->
        {:length, length}

      true ->
        :until_close
    end
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  defp content_length(headers) do
    with value when is_binary(value) <- header(headers, "content-length"),
         {length, ""} when length >= 0 <- Integer.parse(String.trim(value)) do
      length
    else
      _ -> nil
    end
  end

  defp body_stream(tunnel, mode, initial, timeout) do
    Stream.resource(
      fn -> %{tunnel: tunnel, mode: mode, buffer: initial, timeout: timeout, done: false} end,
      &next/1,
      fn _state -> :ok end
    )
  end

  defp next(%{done: true} = state), do: {:halt, state}

  defp next(state) do
    case step(state.mode, state.buffer) do
      {:emit, chunks, mode, buffer} ->
        {chunks, %{state | mode: mode, buffer: buffer}}

      {:done, chunks} ->
        {chunks, %{state | done: true}}

      {:more, mode, buffer} ->
        case receive_body(state) do
          {:data, data} -> next(%{state | mode: mode, buffer: buffer <> data})
          :closed -> {closed_tail(mode, buffer), %{state | done: true}}
        end
    end
  end

  defp receive_body(%{tunnel: tunnel, timeout: timeout}) do
    receive do
      {:tunnel, ^tunnel, {:data, data}} ->
        {:data, data}

      {:tunnel, ^tunnel, :closed} ->
        :closed

      {:tunnel, ^tunnel, {:error, reason}} ->
        raise Error.new(502, "The preview connection failed: #{format(reason)}")
    after
      timeout ->
        raise Error.new(504, "The preview stopped sending.")
    end
  end

  # A close is how a length-less body ends and an error for every other kind.
  defp closed_tail(:until_close, buffer), do: pieces(buffer)

  defp closed_tail(_mode, _buffer),
    do: raise(Error.new(502, "The preview closed the connection before the body ended."))

  defp step(:none, _buffer), do: {:done, []}

  defp step(:until_close, <<>>), do: {:more, :until_close, <<>>}
  defp step(:until_close, buffer), do: {:emit, [buffer], :until_close, <<>>}

  defp step({:length, 0}, _buffer), do: {:done, []}
  defp step({:length, remaining}, <<>>), do: {:more, {:length, remaining}, <<>>}

  defp step({:length, remaining}, buffer) do
    take = min(remaining, byte_size(buffer))
    <<chunk::binary-size(take), rest::binary>> = buffer

    if remaining == take,
      do: {:done, [chunk]},
      else: {:emit, [chunk], {:length, remaining - take}, rest}
  end

  defp step({:chunked, :size}, buffer) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        case chunk_size(line) do
          0 -> step({:chunked, :trailers}, rest)
          size when is_integer(size) -> step({:chunked, {:data, size}}, rest)
          :error -> raise Error.new(502, "The preview sent a malformed chunked body.")
        end

      [_partial] when byte_size(buffer) > @max_head ->
        raise Error.new(502, "The preview sent a malformed chunked body.")

      [_partial] ->
        {:more, {:chunked, :size}, buffer}
    end
  end

  defp step({:chunked, {:data, remaining}}, <<>>),
    do: {:more, {:chunked, {:data, remaining}}, <<>>}

  defp step({:chunked, {:data, remaining}}, buffer) do
    take = min(remaining, byte_size(buffer))
    <<chunk::binary-size(take), rest::binary>> = buffer

    if remaining == take,
      do: {:emit, [chunk], {:chunked, :crlf}, rest},
      else: {:emit, [chunk], {:chunked, {:data, remaining - take}}, rest}
  end

  defp step({:chunked, :crlf}, <<"\r\n", rest::binary>>), do: step({:chunked, :size}, rest)

  defp step({:chunked, :crlf}, buffer) when byte_size(buffer) < 2,
    do: {:more, {:chunked, :crlf}, buffer}

  defp step({:chunked, :crlf}, _buffer),
    do: raise(Error.new(502, "The preview sent a malformed chunked body."))

  defp step({:chunked, :trailers}, <<"\r\n", _rest::binary>>), do: {:done, []}

  defp step({:chunked, :trailers}, buffer) do
    case :binary.split(buffer, "\r\n") do
      [_trailer, rest] -> step({:chunked, :trailers}, rest)
      [_partial] -> {:more, {:chunked, :trailers}, buffer}
    end
  end

  # The size line is hex, optionally followed by `;extensions`.
  defp chunk_size(line) do
    [hex | _extensions] = String.split(line, ";", parts: 2)

    case Integer.parse(String.trim(hex), 16) do
      {size, ""} when size >= 0 -> size
      _other -> :error
    end
  end

  defp pieces(<<>>), do: []
  defp pieces(buffer), do: [buffer]

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp format(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format(reason), do: inspect(reason)
end
