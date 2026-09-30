defmodule Ravix.Tracks.TitleTest do
  use ExUnit.Case, async: true

  alias Ravix.Tracks.Title

  describe "from_prompt/1" do
    test "a short request keeps its words, in title case" do
      assert Title.from_prompt("pull latest main") == "Pull Latest Main"
    end

    test "politeness, articles and intensifiers go; the key phrase stays" do
      assert Title.from_prompt(
               "make the product much more simple and intuitive, I think there's too much going on"
             ) == "Make Product Simple and Intuitive"

      assert Title.from_prompt("Hey, could you please add dark mode to the settings page?") ==
               "Add Dark Mode to Settings"

      assert Title.from_prompt("I'd like you to write tests for the billing module") ==
               "Write Tests for Billing Module"
    end

    test "the explanation after a clause marker goes once the request stands on its own" do
      assert Title.from_prompt(
               "Please add pagination to the tracks endpoint so that the sidebar doesn't load everything at once"
             ) == "Add Pagination to Tracks Endpoint"

      # Too few words before "where" to stand alone, so the marker goes and
      # the words after it stay.
      assert Title.from_prompt(
               "Can you fix the bug where the login page crashes when the password is empty?"
             ) == "Fix Bug Login Page Crashes"
    end

    test "a soft line break does not end the sentence; a blank line does" do
      assert Title.from_prompt("Explain the\nprompt queue") == "Explain Prompt Queue"
      assert Title.from_prompt("Explain the queue\n\nThen fix it") == "Explain Queue"
    end

    test "a phrase cut short leaves no dangling half of a pair" do
      assert Title.from_prompt("Can you pull the latest main and fix the conflicts?") ==
               "Pull Latest Main"

      assert Title.from_prompt("ok, so, fix the build") == "Fix Build"
    end

    test "only the first sentence with words in it is read" do
      assert Title.from_prompt("Rename the queue module. Then update every caller and the docs.") ==
               "Rename Queue Module"
    end

    test "a very long prompt is at most five words and forty characters, cut on a word" do
      long =
        "Investigate intermittent websocket disconnections affecting collaborative editing sessions " <>
          String.duplicate("and explain everything in detail ", 200)

      title = Title.from_prompt(long)
      assert title == "Investigate Intermittent Websocket"
      assert String.length(title) <= Title.max_length()
      assert length(String.split(title)) <= 5
    end

    test "one word longer than the limit is cut with an ellipsis" do
      title = Title.from_prompt(String.duplicate("a", 30) <> String.duplicate("b", 30))
      assert String.length(title) == Title.max_length()
      assert String.ends_with?(title, "…")
    end

    test "code, links, paths and mentions are what the prompt is about, not its title" do
      assert Title.from_prompt("Refactor `Ravix.Tracks.prompt/3` into smaller functions") ==
               "Refactor into Smaller Functions"

      assert Title.from_prompt(
               "look at https://github.com/acme/ledger/issues/12 and tell @alice why CI fails"
             ) == "Look and Tell CI Fails"

      assert Title.from_prompt("Update lib/ravix/tracks.ex to log retries") ==
               "Update to Log Retries"
    end

    test "prose around a code block is the title; the code is not" do
      prompt = """
      Why does this crash on empty input?

      ```elixir
      def parse(""), do: raise "boom"
      ```
      """

      assert Title.from_prompt(prompt) == "Crash on Empty Input"
    end

    test "a prompt that is only code is named by its language, or as code" do
      assert Title.from_prompt("```elixir\ndef foo(x), do: x + 1\n```") == "Elixir Snippet"
      assert Title.from_prompt("```\nfoo()\n```") == "Code Snippet"
      assert Title.from_prompt("def foo(x) do\n  {:ok, x}\nend") == "Code Snippet"

      assert Title.from_prompt("SELECT * FROM tracks WHERE closed_at IS NULL;") ==
               "Code Snippet"
    end

    test "non-English prompts keep their words and are cut by length" do
      assert Title.from_prompt("Bitte den Login-Fehler auf der Startseite beheben") ==
               "Login-Fehler auf Startseite Beheben"

      assert Title.from_prompt("Ajoute un mode sombre à la page des paramètres") ==
               "Ajoute Mode Sombre à Page"

      assert Title.from_prompt("Añade paginación a la lista de pedidos") ==
               "Añade Paginación Lista de Pedidos"

      # No spaces between words: the first sentence, its clauses as words.
      assert Title.from_prompt("修复登录页面在密码为空时崩溃的错误，并添加测试用例。然后部署") ==
               "修复登录页面在密码为空时崩溃的错误 并添加测试用例"

      assert Title.from_prompt("ログイン画面のバグを直して") == "ログイン画面のバグを直して"
    end

    test "acronyms and identifiers keep their insides" do
      assert Title.from_prompt("migrate the API to useEffect hooks") ==
               "Migrate API to UseEffect Hooks"
    end

    test "nothing to title answers nil" do
      assert Title.from_prompt("   \n  ") == nil
      assert Title.from_prompt("") == nil
      assert Title.from_prompt(nil) == nil
      assert Title.from_prompt("please") == nil
    end
  end

  describe "runtime/1" do
    test "a runtime's own title keeps its wording, trimmed and fitted" do
      assert Title.runtime("Main branch pull") == "Main branch pull"
      assert Title.runtime("  \"Fix login crash\"\n") == "Fix login crash"

      assert Title.runtime("Fix login crash on empty password handling in auth module") ==
               "Fix login crash on empty password"
    end

    test "an empty or missing title is none" do
      assert Title.runtime(" \"\" ") == nil
      assert Title.runtime(nil) == nil
    end
  end
end
