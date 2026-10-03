defmodule Ravix.Projects.ConductorSetup.ParserTest do
  use ExUnit.Case, async: true
  alias Ravix.Projects.ConductorSetup.Parser

  @toml ".conductor/settings.toml"
  @json "conductor.json"

  test "real TOML parsing handles multiline setup, quoted ids, arguments and named defaults" do
    {:ok, report} =
      Parser.parse(%{
        @toml => ~S'''
        file_include_globs = ".env.local\ncerts/**"
        [scripts]
        setup = """
        npm ci
        mix deps.get
        """
        run_mode = "nonconcurrent"
        archive = "./cleanup"
        [scripts.run."web.dev"]
        command = "npm run dev -- --port $PORT"
        args = ["has space", "can't", "$(unsafe)"]
        available_in = "cloud"
        default = true
        options = { cwd = "apps/web" }
        [scripts.run.mac]
        command = "open Xcode.app"
        available_in = ["local"]
        '''
      })

    assert report.setup.command == "npm ci\nmix deps.get\n"
    assert [mac, web] = report.runs
    refute mac.selectable?
    refute mac.cloud?
    assert web.cloud? and web.default? and web.selectable?
    assert web.directory == "apps/web"
    assert web.command == "npm run dev -- --port $PORT 'has space' 'can'\\''t' '$(unsafe)'"
    assert length(report.warnings) == 2
    assert report.patterns == [".env.local", "certs/**"]
  end

  test "TOML owns scripts and ignores malformed JSON when setup is present" do
    assert {:ok, report} =
             Parser.parse(%{
               @toml => "[scripts]\nsetup = 'toml'\nrun = 'web'",
               @json => "invalid"
             })

    assert report.setup.command == "toml"
    assert hd(report.runs).command == "web"
  end

  test "cloud setup-only fallback never imports legacy run/archive over TOML" do
    assert {:ok, report} =
             Parser.parse(%{
               @toml => "[scripts]\nrun = 'toml-run'",
               @json =>
                 Jason.encode!(%{
                   scripts: %{setup: "legacy-setup", run: "legacy-run", archive: "remove"}
                 })
             })

    assert report.setup.command == "legacy-setup"
    assert hd(report.runs).command == "toml-run"
    assert length(report.warnings) == 1
  end

  test "legacy JSON scripts and run-mode are supported when TOML is missing" do
    assert {:ok, report} =
             Parser.parse(%{
               @json =>
                 ~s({"scripts":{"setup":"npm ci","run":"npm start","archive":"cleanup"},"runScriptMode":"concurrent"})
             })

    assert report.setup.command == "npm ci"
    assert hd(report.runs).id == "run"
    assert length(report.warnings) == 2
  end

  test "worktreeinclude wins even when empty and preserves negations without resolving files" do
    assert {:ok, report} =
             Parser.parse(%{
               @toml => "file_include_globs = '.env*'",
               ".worktreeinclude" =>
                 "# provisioning\n/config/**\n!config/public.json\n\\#literal\n"
             })

    assert report.patterns == ["/config/**", "!config/public.json", "\\#literal"]
    assert {:ok, %{patterns: []}} = Parser.parse(%{".worktreeinclude" => ""})
    assert {:ok, %{patterns: [".env*"], runs: [], setup: nil, sources: []}} = Parser.parse(%{})
  end

  test "invalid, missing, UTF-8 and bounded file errors are predictable" do
    for files <- [
          %{@toml => "[invalid", @json => "{}"},
          %{@json => "[]"},
          %{@json => "{"},
          %{@toml => String.duplicate(" ", 65_537)},
          %{@toml => <<255>>},
          %{@toml => 1},
          %{@toml => "scripts = 'wrong'"},
          %{@json => ~s({"scripts":{"setup":42}})},
          %{@toml => "file_include_globs = 42"},
          %{".worktreeinclude" => Enum.join(1..101, "\n")}
        ] do
      assert {:error, {:unprocessable, "conductor_setup", _}} = Parser.parse(files)
    end
  end

  test "empty scripts mean no candidate and empty arguments retain their shell meaning" do
    assert {:ok, %{setup: nil, runs: []}} =
             Parser.parse(%{
               @toml => "[scripts]\nsetup = ''\nrun = ''",
               @json => "invalid ignored JSON"
             })

    assert {:ok, %{runs: [%{command: "echo ''"}]}} =
             Parser.parse(%{@toml => "[scripts.run.dev]\ncommand = 'echo'\nargs = ['']"})

    for value <- [false, nil] do
      assert {:error, _} = Parser.parse(%{@json => Jason.encode!(%{scripts: value})})
    end
  end

  test "script limits and invalid schema values are refused" do
    for run <- [
          1,
          Enum.into(1..33, %{}, &{to_string(&1), %{command: "ok"}}),
          %{bad: "bad"},
          %{bad: %{command: "ok", available_in: ["remote"]}},
          %{bad: %{command: "ok", args: 3}},
          %{bad: %{command: "ok", options: 3}},
          %{bad: %{command: "ok", default: "true"}},
          %{bad: %{command: ""}},
          %{bad: %{command: "ok", args: [12]}},
          %{bad: %{command: "x\0"}}
        ] do
      assert {:error, _} = Parser.parse(%{@json => Jason.encode!(%{scripts: %{run: run}})})
    end
  end

  test "unsupported variables and paths require manual review and cannot be selected" do
    {:ok, report} =
      Parser.parse(%{
        @toml => ~S'''
        spotlight_testing = true
        [environment_variables]
        SECRET = "not imported"
        [scripts]
        setup = "echo $CONDUCTOR_IS_LOCAL"
        auto_run_after_setup = true
        [scripts.run.port]
        command = "npm dev --port ${CONDUCTOR_PORT}"
        [scripts.run.path]
        command = "npm dev"
        options = { cwd = "../outside" }
        '''
      })

    long =
      Jason.encode!(%{
        scripts: %{
          run: %{
            long: %{command: "npm dev", args: List.duplicate(String.duplicate("x", 1_000), 8)}
          }
        }
      })

    assert {:ok, %{runs: [%{selectable?: false}]}} = Parser.parse(%{@json => long})

    refute report.setup.selectable?
    assert Enum.all?(report.runs, &(not &1.selectable?))
    assert length(report.warnings) == 3

    for id <- Enum.map(report.runs, & &1.id),
        do: assert({:error, _} = Parser.select(report, %{"run" => id}))

    assert {:error, _} = Parser.select(report, %{"setup" => "true"})
  end

  test "selection only returns explicitly chosen fields, never guesses from defaults" do
    {:ok, report} =
      Parser.parse(%{
        @toml =>
          "[scripts]\nsetup = 'npm ci'\n[scripts.run.dev]\ncommand = 'npm dev --port $PORT'\ndefault = true"
      })

    assert {:ok, %{setup: nil, run: nil}} = Parser.select(report, %{})

    assert {:ok, %{setup: nil, run: nil}} =
             Parser.select(report, %{"setup" => "false", "run" => ""})

    assert {:ok, %{setup: "npm ci", run: nil}} = Parser.select(report, %{"setup" => "true"})

    assert {:ok, %{setup: nil, run: %{"directory" => ".", "command" => "npm dev --port $PORT"}}} =
             Parser.select(report, %{"run" => "dev"})

    assert {:error, _} = Parser.select(report, %{"run" => "forged"})
    assert {:error, _} = Parser.select(report, %{"setup" => "forged"})
    assert {:error, _} = Parser.select(%{setup: nil}, %{"setup" => "true"})
  end
end
