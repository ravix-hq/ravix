defmodule Ravix.Providers do
  @moduledoc """
  The three integrations this server is built on, or the one refusal that
  says which of them is missing.

  A deployment can run without any of them: no `FOUNTAIN_API_KEY` means no
  machines, no GitHub App means sign-in and repositories are off, no
  `SPRITES_TOKEN` means no terminal or previews. Each is a real, supported
  state and the pages have a sentence for it. What they must not have is a
  different sentence *per context*: "no Fountain" used to be spoken by
  `Ravix.Tracks`, `Ravix.Projects` and `Ravix.Accounts.Inference` in three
  copies and two shapes, and the web layer chose a code by which copy it was
  handed.

  So the refusal is one value, `{:error, {:unconfigured, provider}}`, with
  the provider a bounded atom. The adapters (`Ravix.Fountain`, `Ravix.GitHub`,
  `Ravix.Sprites`) answer it when handed a nil config; these readers answer
  it before a call is made; contexts pass it through unchanged; and
  `RavixWeb.Error` holds the one code and the one sentence for each. Nothing
  between the reader and the page names the provider's absence in words.

  Read at call time, never cached, like `Ravix.Config` under it.
  """

  alias Ravix.Config
  alias Ravix.Fountain.Client

  @typedoc "Which integration is missing."
  @type provider :: :fountain | :github | :sprites

  @typedoc "The refusal every context passes through unchanged."
  @type unconfigured :: {:unconfigured, provider()}

  @doc "The Fountain client, or `{:unconfigured, :fountain}` when this deployment has no key."
  @spec fountain() :: {:ok, Client.t()} | {:error, {:unconfigured, :fountain}}
  def fountain do
    client = Ravix.Fountain.client()

    if Client.configured?(client),
      do: {:ok, client},
      else: {:error, {:unconfigured, :fountain}}
  end

  @doc "The GitHub App, or `{:unconfigured, :github}` when it is not all there."
  @spec github() :: {:ok, Config.GitHubApp.t()} | {:error, {:unconfigured, :github}}
  def github do
    case Config.github() do
      nil -> {:error, {:unconfigured, :github}}
      app -> {:ok, app}
    end
  end

  @doc "The Sprites token and base URL, or `{:unconfigured, :sprites}` without a token."
  @spec sprites() :: {:ok, Config.Sprites.t()} | {:error, {:unconfigured, :sprites}}
  def sprites do
    case Config.sprites() do
      nil -> {:error, {:unconfigured, :sprites}}
      cfg -> {:ok, cfg}
    end
  end
end
