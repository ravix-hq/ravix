defmodule RavixWeb.ModelName do
  @moduledoc """
  A model id as a person would say it: `anthropic/claude-opus-5` is
  "Claude Opus 5" and `openai/gpt-6-astra` is "GPT-6 Astra".

  The provider prefix goes, plain words are title-cased, and adjacent
  version numbers are joined with a dot (`claude-sonnet-4-5` is
  "Claude Sonnet 4.5"). A token mixing letters and digits (`4o`, `o3`) is
  kept as written, since capitalising it would spell a different model.
  This is display only: the raw id stays wherever it is sent or stored.
  """

  @acronyms %{"gpt" => "GPT"}

  @doc "The friendly name for a model id; a blank id is an empty string."
  @spec friendly(String.t() | nil) :: String.t()
  def friendly(nil), do: ""

  def friendly(id) when is_binary(id) do
    id
    |> String.split("/")
    |> List.last()
    |> String.split(["-", "_", " "], trim: true)
    |> Enum.map(&token/1)
    |> join([])
  end

  defp token(text) do
    cond do
      acronym = @acronyms[String.downcase(text)] -> {:acronym, acronym}
      text =~ ~r/^\d+$/ -> {:number, text}
      text =~ ~r/^[[:alpha:]]+$/u -> {:word, String.capitalize(text)}
      true -> {:word, text}
    end
  end

  # An acronym followed by something starting with a digit is one word
  # ("GPT-6", "GPT-4o"); two numbers in a row are a dotted version.
  defp join([], acc), do: acc |> Enum.reverse() |> Enum.join(" ")

  defp join([{:acronym, a}, {_, <<d, _::binary>> = v} | rest], acc) when d in ?0..?9,
    do: join([{:word, a <> "-" <> v} | rest], acc)

  defp join([{:number, a}, {:number, b} | rest], acc),
    do: join([{:number, a <> "." <> b} | rest], acc)

  defp join([{_, text} | rest], acc), do: join(rest, [text | acc])
end
