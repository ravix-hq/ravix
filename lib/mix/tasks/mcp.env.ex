defmodule Mix.Tasks.Mcp.Env do
  @shortdoc "Write .env with the MCP credentials from Infisical"

  @moduledoc """
  Write `.env` with the credentials the MCP servers in `.mcp.json` need.

      mix mcp.env

  The values come from the Infisical `ravix` project's **dev** environment, which
  is where developer tooling lives --- `prod` mirrors what the deployed service
  runs on, and the application never reads any of these. `direnv` then loads
  `.env` through `.envrc`, and Claude Code expands the values into `.mcp.json`
  from the process environment. It does *not* read `.env` itself, which is the
  whole reason this file and `.envrc` exist.

  This task is here so three credentials are never hand-copied between a browser,
  a password manager and a shell. Two things in it are worth more than that
  convenience, and both are tested:

    * It **refuses to write unless git already ignores the path.** Writing
      credentials somewhere the repository would commit them is the one way this
      could do real harm, and `.gitignore` covering `.env` today is not a reason
      to assume it will tomorrow.
    * It **says which values are still blank.** A blank is worse than a missing
      one here: Claude Code reports an unset variable by name, while a blank one
      reaches the provider and comes back as a 401 with nothing pointing at the
      cause.

  `infisical run --projectId <id> --env=dev -- claude` does the same job with
  nothing on disk. See the README's "Agent tooling (MCP)".
  """

  use Mix.Task

  # The Infisical project. Not a secret -- an identifier, and the CLI still needs
  # a logged-in user or a machine identity to read anything with it.
  @project "f382332b-11a1-4573-a986-78c1729dbc70"
  @env "dev"
  @path ".env"

  @impl Mix.Task
  def run(_args) do
    unless ignored?(@path) do
      Mix.raise("""
      #{@path} is not ignored by git, so writing credentials there would risk
      committing them. Add it to .gitignore before running this.
      """)
    end

    unless System.find_executable("infisical") do
      Mix.raise("""
      The Infisical CLI is not on PATH.

          brew install infisical/get-cli/infisical && infisical login

      Or skip the file and start the agent with the values injected instead:

          infisical run --projectId #{@project} --env=#{@env} -- claude
      """)
    end

    {output, status} =
      System.cmd(
        "infisical",
        ["export", "--projectId", @project, "--env", @env, "--format", "dotenv"],
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("infisical export failed (#{status}):\n\n#{output}")

    case parse(output) do
      {:ok, values} -> report(values, write(@path, values))
      {:error, reason} -> Mix.raise(reason)
    end
  end

  @doc """
  Infisical's dotenv output as sorted `{name, value}` pairs.

  Separated from the shelling out so the part with judgement in it can be tested.
  Lines that are not `NAME=value` are dropped rather than guessed at: the CLI
  prints progress and warnings on the same stream, and one of those reaching
  `.env` would make the file unparseable.
  """
  @spec parse(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def parse(output) when is_binary(output) do
    values =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&Regex.match?(~r/^[A-Z][A-Z0-9_]*=/, &1))
      |> Enum.map(fn line ->
        [name, value] = String.split(line, "=", parts: 2)
        {name, value}
      end)
      |> Enum.sort()

    if values == [],
      do: {:error, "Infisical returned no secrets for the #{@env} environment."},
      else: {:ok, values}
  end

  @doc """
  Whether a value counts as present.

  Blank is its own outcome rather than absence, because it is the worse of the
  two: Claude Code reports an unset variable by name, while a blank one reaches
  the provider and comes back as a 401 with nothing pointing at the cause.
  """
  @spec state(String.t()) :: :set | :blank
  def state(value) when is_binary(value),
    do: if(String.trim(value) == "", do: :blank, else: :set)

  @doc """
  Whether git ignores `path`.

  `git check-ignore` rather than reading `.gitignore`, so that a global ignore
  file, an `info/exclude` or a negated pattern all count the same way git counts
  them. Anything that is not a clear "yes" is treated as "no": outside a
  repository, or with git missing, refusing to write is the safe answer.
  """
  @spec ignored?(String.t()) :: boolean()
  def ignored?(path) when is_binary(path) do
    case System.cmd("git", ["check-ignore", "-q", "--", path], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  @doc """
  Write `values` to `path`, readable only by its owner, and answer the path.

  The mode is the point: this file holds three credentials in plaintext, and
  `0600` is what keeps it out of reach of anything else running as another user
  on a shared machine. Public so that a test can assert the mode against a
  temporary path rather than against the developer's real `.env`.
  """
  @spec write(String.t(), [{String.t(), String.t()}]) :: String.t()
  def write(path, values) do
    body = Enum.map_join(values, "\n", fn {name, value} -> name <> "=" <> value end)
    File.write!(path, body <> "\n")
    File.chmod!(path, 0o600)
    path
  end

  defp report(values, path) do
    Mix.shell().info("Wrote #{path} (0600) with #{length(values)} value(s).")

    for {name, value} <- values do
      case state(value) do
        :set -> Mix.shell().info("  set    #{name}")
        :blank -> Mix.shell().info([:yellow, "  blank  #{name} -- still a placeholder"])
      end
    end

    Mix.shell().info("\nRun `direnv allow` once, then `claude`.")
  end
end
