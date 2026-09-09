defmodule RavixWeb.PreviewGateway.Frame do
  @moduledoc """
  RFC 6455 framing for the sprite side of a relayed WebSocket.

  Bandit frames the browser side; the tunnel to the app is a raw duplex once
  the upgrade is answered, and on it the gateway is the client: it sends
  masked frames and expects unmasked ones back. Fragmented messages are
  reassembled, control frames may interleave, and a payload over one MiB
  (the TypeScript `maxPayload`) ends the connection rather than the memory.
  """

  import Bitwise

  @max_payload 1024 * 1024

  @type frame ::
          {:text, binary()}
          | {:binary, binary()}
          | {:ping, binary()}
          | {:pong, binary()}
          | {:close, non_neg_integer() | nil, binary()}

  @opaque decoder :: %__MODULE__{
            buffer: binary(),
            fragment: nil | {:text | :binary, [binary()], non_neg_integer()}
          }
  defstruct buffer: <<>>, fragment: nil

  @doc "A decoder with nothing pending."
  @spec new() :: decoder()
  def new, do: %__MODULE__{}

  @doc "One masked, unfragmented frame as the client sends it."
  @spec encode(frame()) :: iodata()
  def encode({:close, code, reason}) do
    payload = if code, do: <<code::16, reason::binary>>, else: <<>>
    encode_frame(8, payload)
  end

  def encode({opcode, data}) do
    payload = IO.iodata_to_binary(data)

    case opcode do
      :text -> encode_frame(1, payload)
      :binary -> encode_frame(2, payload)
      :ping -> encode_frame(9, payload)
      :pong -> encode_frame(10, payload)
    end
  end

  @doc "Feed bytes from the app; every complete message so far, in order."
  @spec decode(decoder(), binary()) :: {:ok, [frame()], decoder()} | {:error, term()}
  def decode(%__MODULE__{buffer: buffer} = decoder, data) do
    parse(%{decoder | buffer: buffer <> data}, [])
  end

  defp parse(%__MODULE__{buffer: buffer} = decoder, acc) do
    case header(buffer) do
      {:ok, fin, opcode, length, rest} when byte_size(rest) >= length ->
        <<payload::binary-size(length), rest::binary>> = rest

        case message(decoder, fin, opcode, payload) do
          {:ok, frames, decoder} -> parse(%{decoder | buffer: rest}, Enum.reverse(frames) ++ acc)
          {:error, reason} -> {:error, reason}
        end

      {:ok, _, _, _, _} ->
        {:ok, Enum.reverse(acc), decoder}

      :more ->
        {:ok, Enum.reverse(acc), decoder}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # {:ok, fin?, opcode, payload_length, rest_after_header}
  defp header(<<fin::1, _rsv::3, opcode::4, 0::1, len::7, rest::binary>>) do
    with {:ok, length, rest} <- payload_length(len, rest),
         :ok <- check_length(opcode, length) do
      {:ok, fin == 1, opcode, length, rest}
    end
  end

  defp header(<<_::8, 1::1, _::7, _::binary>>), do: {:error, :masked_server_frame}
  defp header(_), do: :more

  defp payload_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp payload_length(len, rest) when len < 126, do: {:ok, len, rest}
  defp payload_length(_, _), do: :more

  defp check_length(opcode, length) when opcode >= 8 and length > 125,
    do: {:error, :control_frame_too_large}

  defp check_length(_opcode, length) when length > @max_payload, do: {:error, :max_payload}
  defp check_length(_, _), do: :ok

  # Control frames, which may sit between fragments of a message.
  defp message(decoder, true, 8, payload) do
    case payload do
      <<code::16, reason::binary>> -> {:ok, [{:close, code, reason}], decoder}
      <<>> -> {:ok, [{:close, nil, <<>>}], decoder}
      _ -> {:error, :malformed_close}
    end
  end

  defp message(decoder, true, 9, payload), do: {:ok, [{:ping, payload}], decoder}
  defp message(decoder, true, 10, payload), do: {:ok, [{:pong, payload}], decoder}

  defp message(_decoder, false, opcode, _payload) when opcode >= 8,
    do: {:error, :fragmented_control}

  # Data frames: whole, first fragment, continuation, last fragment.
  defp message(%{fragment: nil} = decoder, true, opcode, payload) when opcode in [1, 2],
    do: {:ok, [{data_type(opcode), payload}], decoder}

  defp message(%{fragment: nil} = decoder, false, opcode, payload) when opcode in [1, 2],
    do: {:ok, [], %{decoder | fragment: {data_type(opcode), [payload], byte_size(payload)}}}

  defp message(%{fragment: {type, parts, size}} = decoder, fin, 0, payload) do
    size = size + byte_size(payload)

    cond do
      size > @max_payload ->
        {:error, :max_payload}

      fin ->
        {:ok, [{type, IO.iodata_to_binary(Enum.reverse([payload | parts]))}],
         %{decoder | fragment: nil}}

      true ->
        {:ok, [], %{decoder | fragment: {type, [payload | parts], size}}}
    end
  end

  defp message(_decoder, _fin, _opcode, _payload), do: {:error, :unexpected_frame}

  defp data_type(1), do: :text
  defp data_type(2), do: :binary

  defp encode_frame(opcode, payload) do
    key = :crypto.strong_rand_bytes(4)
    size = byte_size(payload)

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    [<<1::1, 0::3, opcode::4>>, length, key, mask(payload, key)]
  end

  defp mask(payload, <<key::32>> = key_bytes), do: mask(payload, key_bytes, key, [])

  defp mask(<<word::32, rest::binary>>, key_bytes, key, acc),
    do: mask(rest, key_bytes, key, [acc, <<bxor(word, key)::32>>])

  defp mask(<<>>, _key_bytes, _key, acc), do: acc

  defp mask(tail, key_bytes, _key, acc) do
    masked =
      tail
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, i} -> bxor(byte, :binary.at(key_bytes, i)) end)

    [acc, masked]
  end
end
