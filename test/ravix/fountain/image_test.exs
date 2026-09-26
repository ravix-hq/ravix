defmodule Ravix.Fountain.ImageTest do
  use ExUnit.Case, async: true

  alias Ravix.Fountain.Image

  test "recognizes accepted image formats from bytes rather than supplied content types" do
    for {bytes, type} <- [
          {<<137, "PNG\r\n", 26, "\n", 0>>, "image/png"},
          {<<255, 216, 255, 0>>, "image/jpeg"},
          {"GIF87a\0", "image/gif"},
          {"GIF89a\0", "image/gif"},
          {"RIFF\0\0\0\0WEBP", "image/webp"}
        ] do
      assert {:ok, %Image{data: ^bytes, media_type: ^type}} = Image.decode(bytes)
    end
  end

  test "rejects non-images and oversized responses" do
    for bytes <- [
          nil,
          %{},
          "",
          "<html>bad</html>",
          "<svg/>",
          "GIF89a" <> :binary.copy(<<0>>, 8 * 1024 * 1024)
        ] do
      assert {:error, :not_found} = Image.decode(bytes)
    end
  end
end
