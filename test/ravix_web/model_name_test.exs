defmodule RavixWeb.ModelNameTest do
  use ExUnit.Case, async: true

  alias RavixWeb.ModelName

  test "drops the provider and title-cases the model" do
    assert ModelName.friendly("anthropic/claude-opus-5") == "Claude Opus 5"
    assert ModelName.friendly("anthropic/claude-sonnet-5") == "Claude Sonnet 5"
    assert ModelName.friendly("openai/gpt-6-astra") == "GPT-6 Astra"
  end

  test "joins adjacent version numbers and keeps mixed tokens as written" do
    assert ModelName.friendly("anthropic/claude-sonnet-4-5") == "Claude Sonnet 4.5"
    assert ModelName.friendly("claude-3-5-haiku") == "Claude 3.5 Haiku"
    assert ModelName.friendly("openai/gpt-4o-mini") == "GPT-4o Mini"
    assert ModelName.friendly("openai/o3") == "o3"
    assert ModelName.friendly("gpt") == "GPT"
    assert ModelName.friendly("gpt-astra") == "GPT Astra"
  end

  test "an unprefixed, nested, or blank id still reads sensibly" do
    assert ModelName.friendly("vendor/opus-9") == "Opus 9"
    assert ModelName.friendly("router/vendor/big_model") == "Big Model"
    assert ModelName.friendly("") == ""
    assert ModelName.friendly(nil) == ""
  end
end
