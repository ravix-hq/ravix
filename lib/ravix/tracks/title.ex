defmodule Ravix.Tracks.Title do
  @moduledoc """
  A short display title for a thread, read out of its first prompt.

  "Thread 2" and `ravix/crewe` are names you can tell apart but not
  recognise; "Pull Latest Main" is the thing you asked for. A person writes
  a first prompt as an instruction, though, not a label, so the words are
  thinned before they are kept: the politeness and hedging in front
  ("could you please"), the articles and intensifiers in between, and any
  code, links or file contents, which are what the prompt is *about* rather
  than what it says. What is left is the key phrase, cut to at most five
  words and forty characters and put in title case.

  Deterministic and local on purpose. Ravix must never read the agent
  credential (ADR 0005), so a model is not asked; a title the runtime wrote
  itself is preferred when one arrives (`runtime/1`), and this is what the
  thread is called until then, or for good when no runtime writes one.

  The stopword list is English. Other languages keep every word, which for
  a short prompt is still a readable title, and scripts written without
  spaces are cut by length alone.
  """

  @max_length 40
  @max_words 5

  # Said before the request, never part of it. Longest first, so "could you
  # please" is taken whole rather than leaving "please" behind.
  @lead_ins [
              "i would like you to",
              "i'd like you to",
              "i want you to",
              "i need you to",
              "could you please",
              "can you please",
              "would you please",
              "please could you",
              "please can you",
              "could you",
              "can you",
              "would you",
              "will you",
              "go ahead and",
              "help me to",
              "help me",
              "i want to",
              "i need to",
              "we need to",
              "we should",
              "i think we should",
              "let's",
              "lets",
              "let us",
              "please",
              "hey",
              "hi",
              "hello",
              "ok",
              "okay",
              "so",
              "now",
              "then",
              "also",
              "just"
            ]
            |> Enum.sort_by(&(-String.length(&1)))

  # Words that carry no subject anywhere in the phrase. English, plus the
  # articles and "please" of a few languages whose prompts are common.
  @filler MapSet.new(~w(
    a an the this that these those some any our my your their its it
    much more very really quite rather just please kindly also actually basically
    maybe perhaps probably simply currently all
    is are was were be been being am do does did
    i me we us you he she they them
    there here here's there's it's what's that's
    der die das den dem des ein eine einen bitte
    le la les un une du l'
    el los las una
  ))

  # Kept inside a title, lower case, but never at either end of it, and
  # never two in a row once the words between them have gone.
  @joiners MapSet.new(~w(
    and or of to in on for with from by at as vs via into over
    und mit für von zu auf
    et à de en sur pour avec
    y con para por del
  ))

  # Joiners that pair two things, so the second is not dropped alone.
  @pairs ~w(and or und oder et ou y o)

  # Where a second clause starts: the words after one explain the request
  # rather than name it, once there are enough words before it to stand alone.
  @clauses MapSet.new(~w(
    where when which because since if but while after before until unless why how so
    though although whenever
  ))
  @clause_min 3

  @doc """
  The title a prompt reads as, or nil when it has no words to give one (an
  image on its own, or whitespace). Code with no prose around it is titled
  by its language when the fence names one.
  """
  @spec from_prompt(String.t() | nil) :: String.t() | nil
  def from_prompt(prompt) when is_binary(prompt) do
    {prose, fences} = strip_code(prompt)

    case prose |> first_sentence() |> first_clauses() do
      [] -> code_title(fences)
      words -> words |> take() |> fit() |> title_case()
    end
  end

  def from_prompt(_prompt), do: nil

  @doc """
  A title the runtime wrote for its session (ACP `session_info_update`), as
  Fountain saved it on the conversation, tidied to the same length. Its wording is kept: somebody chose it.
  """
  @spec runtime(String.t() | nil) :: String.t() | nil
  def runtime(title) when is_binary(title) do
    case title
         |> String.split()
         |> Enum.join(" ")
         |> String.replace(~r/^[\s"'`]+|[\s"'`]+$/u, "") do
      "" -> nil
      line -> line |> String.split(" ") |> fit()
    end
  end

  def runtime(_title), do: nil

  @doc "The longest a title is allowed to be."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  # ── the prose ─────────────────────────────────────────────────────────

  # Fenced blocks go, keeping the language each named; inline code, links,
  # paths, mentions and lines that read as code go with them. Code with no
  # fence counts as an unnamed one, and when most lines are code the short
  # lines left between them (`end`, `}` on its own) are code too.
  defp strip_code(prompt) do
    fences =
      ~r/```[ \t]*([\w+#.-]*)[^\n]*\n?.*?(?:```|\z)/s
      |> Regex.scan(prompt)
      |> Enum.map(fn [_, lang] -> lang end)

    # Blank lines stay: they end a sentence.
    lines =
      prompt
      |> String.replace(~r/```.*?(?:```|\z)/s, "\n\n")
      |> String.replace(~r/`[^`\n]*`/u, " ")
      |> String.split("\n")

    {code, prose} = Enum.split_with(lines, &code_line?/1)
    written = Enum.count(prose, &(String.trim(&1) != ""))

    prose =
      if length(code) >= written,
        do: Enum.map(prose, &if(length(String.split(&1)) >= 3, do: &1, else: "")),
        else: prose

    prose =
      prose
      |> Enum.join("\n")
      |> String.replace(~r/\bhttps?:\/\/\S+/u, " ")
      |> String.replace(~r/\S*[\/\\]\S*/u, " ")
      |> String.replace(~r/(^|\s)[@#]\S+/u, " ")

    {prose, if(code == [], do: fences, else: fences ++ [""])}
  end

  # A line dense with punctuation, or ending the way a statement or a block
  # does, is code, a path, a stack frame or a table, none of which says what
  # the prompt is asking for.
  defp code_line?(line) do
    chars = line |> String.replace(~r/\s/u, "") |> String.graphemes()
    symbols = Enum.count(chars, &String.match?(&1, ~r/^[{}()\[\];=<>|\/\\:$&*^%]$/))

    chars != [] and (symbols / length(chars) > 0.12 or String.match?(line, ~r/[;{}]\s*$/))
  end

  # The request is almost always in the first sentence that has words in it.
  # A single line break is a soft wrap; a blank line or a colon ends one.
  defp first_sentence(prose) do
    prose
    |> String.split(~r/(?<=[.!?:])\s+|[。！？]+|\n\s*\n/u, trim: true)
    |> Enum.find("", &String.match?(&1, ~r/\p{L}/u))
  end

  # Comma-separated clauses, as many as it takes to name something: "make
  # the product simpler and clearer, I think there is too much going on"
  # stops at the comma, and "ok, so, fix the build" reads on past both.
  defp first_clauses(sentence) do
    sentence
    |> String.split(~r/[,;，；、]/u)
    |> Enum.reduce_while("", fn clause, text ->
      text = text <> " " <> clause
      words = text |> words() |> thin()

      if Enum.count(words, &(not joiner?(&1))) >= @clause_min,
        do: {:halt, {:named, words}},
        else: {:cont, text}
    end)
    |> case do
      {:named, words} -> words
      text -> text |> words() |> thin()
    end
  end

  defp words(sentence) do
    ~r/[\p{L}\p{N}][\p{L}\p{N}\p{M}'’._+-]*/u
    |> Regex.scan(sentence)
    |> Enum.map(fn [word] -> word |> String.trim_trailing(".") |> String.replace("’", "'") end)
    |> Enum.reject(&(&1 == ""))
  end

  defp thin(words) do
    words
    |> drop_lead_ins()
    |> Enum.reject(&MapSet.member?(@filler, String.downcase(&1)))
    |> first_clause([])
    |> Enum.chunk_by(&joiner?/1)
    |> Enum.flat_map(fn [word | _] = run -> if joiner?(word), do: [List.last(run)], else: run end)
    |> trim_joiners()
  end

  defp first_clause([], kept), do: Enum.reverse(kept)

  defp first_clause([word | rest], kept) do
    cond do
      not MapSet.member?(@clauses, String.downcase(word)) -> first_clause(rest, [word | kept])
      Enum.count(kept, &(not joiner?(&1))) >= @clause_min -> Enum.reverse(kept)
      true -> first_clause(rest, kept)
    end
  end

  defp drop_lead_ins(words) do
    lowered = Enum.map(words, &String.downcase/1)

    case Enum.find(@lead_ins, &starts_with?(lowered, String.split(&1))) do
      nil -> words
      phrase -> words |> Enum.drop(length(String.split(phrase))) |> drop_lead_ins()
    end
  end

  defp starts_with?(words, phrase), do: Enum.take(words, length(phrase)) == phrase

  # A phrase cut short leaves no half of a pair behind: "Pull Latest Main
  # and Fix" of "pull latest main and fix the conflicts" is "Pull Latest Main".
  defp take(words) when length(words) <= @max_words, do: words

  defp take(words) do
    kept = Enum.take(words, @max_words)

    case Enum.take(kept, -2) do
      [pair, _word] when length(kept) >= 4 ->
        if String.downcase(pair) in @pairs, do: Enum.drop(kept, -2), else: kept

      _ ->
        kept
    end
  end

  defp trim_joiners(words) do
    words
    |> Enum.drop_while(&joiner?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&joiner?/1)
    |> Enum.reverse()
  end

  defp joiner?(word), do: MapSet.member?(@joiners, String.downcase(word))

  defp code_title(fences) do
    case Enum.find(fences, &(&1 != "")) do
      nil when fences == [] -> nil
      nil -> "Code Snippet"
      lang -> fit([upcase_first(lang), "Snippet"])
    end
  end

  # ── the length ────────────────────────────────────────────────────────

  # Whole words while they fit; one word too long for the limit on its own
  # (a sentence in a script without spaces, a very long identifier) is cut.
  defp fit([first | _] = words) do
    kept =
      words
      |> Enum.reduce_while([], fn word, acc ->
        candidate = Enum.join(Enum.reverse([word | acc]), " ")
        if String.length(candidate) <= @max_length, do: {:cont, [word | acc]}, else: {:halt, acc}
      end)
      |> Enum.reverse()
      |> trim_joiners()

    case kept do
      [] -> String.slice(first, 0, @max_length - 1) <> "…"
      kept -> Enum.join(kept, " ")
    end
  end

  defp title_case(line) do
    line
    |> String.split(" ")
    |> Enum.with_index()
    |> Enum.map_join(" ", fn
      {word, 0} -> upcase_first(word)
      {word, _} -> if joiner?(word), do: String.downcase(word), else: upcase_first(word)
    end)
  end

  # The first letter only, so "API" and "useEffect" keep their own
  # insides and a script with no case is left as it is.
  defp upcase_first(word) do
    case String.next_grapheme(word) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> word
    end
  end
end
