defmodule Mix.Tasks.Mcp.EnvTest do
  @moduledoc """
  The parts of `mix mcp.env` that carry a judgement, rather than the part that
  shells out to Infisical.

  Two of them are worth a test on their own account. `ignored?/1` is what stands
  between this task and writing three credentials to a path the repository would
  commit --- the one way it could do real harm. `state/1` is what distinguishes a
  blank value from a missing one, which matters because blank is the worse of the
  two: Claude Code names a missing variable, while a blank one reaches the
  provider and comes back as a 401 with nothing pointing at the cause.

  No real credential appears here. `parse/1` is given output shaped like the
  CLI's, with values that are obviously not keys.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mcp.Env

  describe "parse/1" do
    test "reads NAME=value lines, sorted" do
      assert Env.parse("""
             RAVIX_RENDER_MCP_KEY=rnd_example
             RAVIX_POSTHOG_MCP_KEY=phx_example
             """) ==
               {:ok,
                [
                  {"RAVIX_POSTHOG_MCP_KEY", "phx_example"},
                  {"RAVIX_RENDER_MCP_KEY", "rnd_example"}
                ]}
    end

    test "keeps a value containing a colon whole" do
      # Honeycomb's management key is `KEY_ID:SECRET`, and splitting on the
      # first `=` only is what keeps it intact.
      assert {:ok, [{"RAVIX_HONEYCOMB_MCP_KEY", "hcamk_abc:def"}]} =
               Env.parse("RAVIX_HONEYCOMB_MCP_KEY=hcamk_abc:def\n")
    end

    test "keeps a value containing an equals sign whole" do
      assert {:ok, [{"A_KEY", "abc=def=ghi"}]} = Env.parse("A_KEY=abc=def=ghi\n")
    end

    test "drops anything that is not a NAME=value line" do
      # The CLI prints progress and warnings on the same stream that carries the
      # secrets, and one of those reaching `.env` makes the file unparseable.
      assert {:ok, [{"A_KEY", "one"}]} =
               Env.parse("""
               [INFO] exporting secrets...
               A_KEY=one
               lowercase=ignored
               not a line at all
               """)
    end

    test "no recognisable lines is an error, not an empty file" do
      # Writing an empty `.env` over a good one would look like success and
      # leave every server unauthenticated.
      assert {:error, message} = Env.parse("[INFO] nothing to export\n")
      assert message =~ "no secrets"
    end
  end

  describe "state/1" do
    test "a value is set" do
      assert Env.state("phx_example") == :set
    end

    test "empty and whitespace are blank" do
      assert Env.state("") == :blank
      assert Env.state(" ") == :blank
      assert Env.state("\t\n") == :blank
    end
  end

  describe "write/2" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "mcp_env_test_#{System.unique_integer([:positive])}.env")

      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "writes a file only its owner can read", %{path: path} do
      # The security property worth a test: this file holds three credentials in
      # plaintext, and 0600 is what keeps it from anything running as another
      # user on a shared machine.
      Env.write(path, [{"A_KEY", "one"}])

      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "writes something parse/1 reads back unchanged", %{path: path} do
      values = [{"A_KEY", "one"}, {"B_KEY", "hcamk_abc:def"}, {"C_KEY", ""}]
      Env.write(path, values)

      assert Env.parse(File.read!(path)) == {:ok, values}
    end

    test "answers the path it wrote", %{path: path} do
      assert Env.write(path, [{"A_KEY", "one"}]) == path
    end
  end

  describe "ignored?/1" do
    test "true for the path this task writes" do
      # `.gitignore` covering `.env` today is not a reason to assume it will
      # tomorrow, which is why the task asks git instead of trusting it.
      assert Env.ignored?(".env")
    end

    test "false for a tracked path" do
      refute Env.ignored?("mix.exs")
    end

    test "false for an untracked path nobody ignores" do
      refute Env.ignored?("README.md")
    end
  end
end
