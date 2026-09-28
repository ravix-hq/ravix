defmodule Mix.Tasks.Ravix.ProviderSecrets do
  @moduledoc """
  List every project whose environment or vault holds a provider-named
  variable or secret (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`).

      mix ravix.provider_secrets

  Run it before turning on `RAVIX_CREATOR_BILLING`: Fountain lets such a
  value outrank a conversation's credential set, so a creator-billed track
  on one of these projects is refused until it is removed
  (`docs/creator-billing.md` §2). In a release, the same list is
  `bin/ravix rpc 'Ravix.Release.provider_secrets()'`.

  Names only. Nothing is read past a key and nothing is written. Exits
  non-zero when anything is listed, so a runbook step can stop on it.
  """
  use Mix.Task

  @shortdoc "Inventory provider-named project secrets, by name, before creator billing"

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")

    case Ravix.Release.provider_secret_lines() do
      [] ->
        Mix.shell().info("No project holds a provider-named variable or secret.")

      lines ->
        Enum.each(lines, fn line -> Mix.shell().info(line) end)
        Mix.raise("#{length(lines)} project(s) hold provider-named values; remove them first.")
    end
  end
end
