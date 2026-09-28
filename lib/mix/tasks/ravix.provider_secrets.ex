defmodule Mix.Tasks.Ravix.ProviderSecrets do
  @moduledoc """
  The creator-billing activation check.

      mix ravix.provider_secrets
      mix ravix.provider_secrets --close-allowlists

  Lists every project whose environment or vault holds a provider-named
  variable or secret (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`,
  `OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`), and
  every project or runtime agent whose credential allowlist Fountain reads as
  open (nil: every set on Ravix's one account).

  Run it before turning on `RAVIX_CREATOR_BILLING`. Fountain lets a
  provider-named value outrank a conversation's credential set, so a
  creator-billed track on such a project is refused until it is removed
  (`docs/creator-billing.md` §2). An open agent would admit any Ravix
  person's set; `--close-allowlists` gives each an explicit empty list first,
  idempotently, under the same lock as every other allowlist writer. In a
  release, the same steps are `bin/ravix rpc 'Ravix.Release.close_open_allowlists()'`
  and `bin/ravix rpc 'Ravix.Release.provider_secrets()'`.

  Names and ids only. Nothing is read past a key, and the only write is
  `--close-allowlists`'s. Exits non-zero when anything is listed, so a runbook
  step can stop on it.
  """
  use Mix.Task

  @shortdoc "Inventory provider-named secrets and open agent allowlists before creator billing"

  @impl true
  def run(argv) do
    # Not app.start: see `Ravix.Release`, no singletons or endpoint for a task.
    Mix.Task.run("app.config")
    Ravix.Release.start_services()

    if "--close-allowlists" in argv do
      Enum.each(Ravix.Release.allowlist_lines(close: true), fn line -> Mix.shell().info(line) end)
    end

    case Ravix.Release.provider_secret_lines() ++ Ravix.Release.allowlist_lines() do
      [] ->
        Mix.shell().info(
          "No project holds a provider-named variable or secret, and no agent is open."
        )

      lines ->
        Enum.each(lines, fn line -> Mix.shell().info(line) end)

        Mix.raise(
          "#{length(lines)} finding(s); remove the values and close the allowlists first."
        )
    end
  end
end
