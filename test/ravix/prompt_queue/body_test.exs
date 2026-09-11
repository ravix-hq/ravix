defmodule Ravix.PromptQueue.BodyTest do
  use ExUnit.Case, async: true

  alias Ravix.PromptQueue.Body
  alias Ravix.PromptQueue.Body.Image

  @image %Image{data: "aGVsbG8=", media_type: "image/png"}

  test "a body round-trips through the shape the column stores" do
    body = %Body{prompt: "look at this", images: [@image]}

    document = Body.encode(body)

    assert document == %{
             "prompt" => "look at this",
             "images" => [%{"data" => "aGVsbG8=", "media_type" => "image/png"}]
           }

    assert Body.decode(document) == body
  end

  # The reason this module exists. An image went into the column as an
  # atom-keyed map and came back out of Postgres with string keys, so the two
  # halves of one round trip were never the same shape in memory.
  test "both spellings decode, because both are what actually arrives" do
    from_postgres = %{
      "prompt" => "look",
      "images" => [%{"data" => "aGVsbG8=", "media_type" => "image/png"}]
    }

    in_memory = %{prompt: "look", images: [%{data: "aGVsbG8=", media_type: "image/png"}]}

    assert Body.decode(from_postgres) == Body.decode(in_memory)
    assert %Body{prompt: "look", images: [@image]} = Body.decode(from_postgres)
  end

  test "a released body is an empty one, not a failure" do
    # `set_status` clears `body` once a row is sent or cancelled: the receipt
    # outlives the megabytes, and asking a receipt what it said is fair.
    assert Body.decode(nil) == %Body{prompt: "", images: []}
    assert Body.decode(nil) == Body.empty()
  end

  test "a body already decoded decodes to itself" do
    body = %Body{prompt: "x", images: [@image]}
    assert Body.decode(body) == body
    assert Image.decode(@image) == [@image]
  end

  test "an entry that is not a usable image is dropped rather than failing delivery" do
    document = %{
      "prompt" => "look",
      "images" => [
        %{"data" => "aGVsbG8=", "media_type" => "image/png"},
        %{"data" => "no type"},
        %{"media_type" => "image/png"},
        %{"data" => 7, "media_type" => "image/png"},
        "junk",
        nil
      ]
    }

    assert %Body{images: [@image]} = Body.decode(document)
  end

  test "a document missing either key reads as empty rather than nil" do
    assert %Body{prompt: "", images: []} = Body.decode(%{})
    assert %Body{prompt: "", images: []} = Body.decode(%{"prompt" => 7, "images" => "nope"})
    assert %Body{prompt: "hi", images: []} = Body.decode(%{"prompt" => "hi"})
  end

  test "an image encodes as the two names Fountain uses" do
    assert Jason.decode!(Jason.encode!(@image)) == %{
             "data" => "aGVsbG8=",
             "media_type" => "image/png"
           }
  end
end
