defmodule Ravix.Fountain.Image do
  @moduledoc "Retained prompt image bytes, limited to the four passive formats accepted on upload."

  @enforce_keys [:data, :media_type]
  defstruct [:data, :media_type]

  @type t :: %__MODULE__{data: binary(), media_type: String.t()}

  @spec decode(term()) :: {:ok, t()} | {:error, :not_found}
  def decode(data) when is_binary(data) and byte_size(data) <= 8 * 1024 * 1024 do
    case media_type(data) do
      nil -> {:error, :not_found}
      type -> {:ok, %__MODULE__{data: data, media_type: type}}
    end
  end

  def decode(_), do: {:error, :not_found}

  defp media_type(<<137, "PNG\r\n", 26, "\n", _::binary>>), do: "image/png"
  defp media_type(<<255, 216, 255, _::binary>>), do: "image/jpeg"
  defp media_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp media_type(<<"GIF89a", _::binary>>), do: "image/gif"
  defp media_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp media_type(_), do: nil
end
