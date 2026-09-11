defmodule Ravix.Previews.ConfigTest do
  use ExUnit.Case, async: true

  alias Ravix.Previews.Config

  defp parse(attrs), do: Config.parse(attrs)

  defp errors(attrs) do
    {:error, changeset} = parse(attrs)
    changeset.errors |> Keyword.keys() |> Enum.sort() |> Enum.uniq()
  end

  defp valid(overrides \\ %{}),
    do: Map.merge(%{directory: "apps/web", command: "npm start", readiness_path: "/"}, overrides)

  test "a whole configuration survives, trimmed" do
    assert {:ok, config} =
             parse(%{directory: "  apps/web  ", command: "  npm start  ", readiness_path: "/"})

    assert config == %Config{
             directory: "apps/web",
             command: "npm start",
             readiness_path: "/"
           }
  end

  test "the track root is spelled the way a shell spells it" do
    assert {:ok, %Config{directory: "."}} = parse(valid(%{directory: ""}))
    assert {:ok, %Config{directory: "."}} = parse(valid(%{directory: "   "}))
  end

  test "nil is an answer and a parsed configuration passes straight through" do
    assert {:ok, nil} = parse(nil)
    config = %Config{directory: ".", command: "run", readiness_path: "/"}
    assert {:ok, ^config} = parse(config)
  end

  test "a missing field is refused on that field rather than crashing" do
    assert errors(%{}) == [:command, :directory, :readiness_path]
    assert errors(%{directory: "."}) == [:command, :readiness_path]
  end

  # The bounds. Each of these is what stops a value reaching a shell, a `cd`
  # or a sprite's HTTP front as something other than it reads as.
  test "the directory cannot leave the track or carry a control character" do
    for directory <- ["/etc", "../up", "a/../../b", "a\nb", "a\0b", String.duplicate("d", 1_001)] do
      assert :directory in errors(valid(%{directory: directory})),
             "accepted directory #{inspect(directory)}"
    end

    # A thousand is the limit, not the first refusal.
    assert {:ok, _} = parse(valid(%{directory: String.duplicate("d", 1_000)}))
  end

  test "the command must be something to run, and not smuggle a null byte" do
    for command <- ["", "   ", "run\0hidden", String.duplicate("c", 8_001)] do
      assert :command in errors(valid(%{command: command})),
             "accepted command #{inspect(command)}"
    end

    assert {:ok, _} = parse(valid(%{command: String.duplicate("c", 8_000)}))
  end

  test "readiness is a path on this app and cannot name another host" do
    paths = [
      "",
      "health",
      "//evil.example",
      "https://evil.example",
      "/with space",
      "/frag#ment",
      "/back\\slash",
      "/\r\n",
      String.duplicate("/p", 501)
    ]

    for path <- paths do
      assert :readiness_path in errors(valid(%{readiness_path: path})),
             "accepted readiness path #{inspect(path)}"
    end
  end

  test "either spelling of the readiness key arrives" do
    assert {:ok, %Config{readiness_path: "/health"}} =
             parse(%{directory: ".", command: "run", readinessPath: "/health"})

    assert {:ok, %Config{readiness_path: "/health"}} =
             parse(%{"directory" => ".", "command" => "run", "readiness_path" => "/health"})
  end

  test "something that is not a configuration has no field to blame" do
    for other <- ["nope", 7, [], true] do
      assert {:error, %Ecto.Changeset{errors: [config: _]}} = parse(other)
    end
  end

  describe "Config.Type" do
    alias Ravix.Previews.Config.Type

    @config %Config{directory: "apps/web", command: "run", readiness_path: "/health"}
    @stored %{"directory" => "apps/web", "command" => "run", "readiness_path" => "/health"}

    test "dump writes the three string keys, which is what the column has always held" do
      assert Type.dump(@config) == {:ok, @stored}
      assert Type.dump(nil) == {:ok, nil}
    end

    test "load reads them back, in whichever spelling the document has" do
      assert Type.load(@stored) == {:ok, @config}
      assert Type.load(nil) == {:ok, nil}

      camel = %{"directory" => "apps/web", "command" => "run", "readinessPath" => "/health"}
      assert Type.load(camel) == {:ok, @config}
    end

    test "cast takes the struct it is given, or a document, and refuses anything else" do
      assert Type.cast(@config) == {:ok, @config}
      assert Type.cast(@stored) == {:ok, @config}
      assert Type.cast(nil) == {:ok, nil}

      for other <- ["nope", 7, [], true] do
        assert Type.cast(other) == :error
      end
    end

    test "cast does not re-validate: that is parse/1's, at the boundary somebody typed at" do
      # A configuration this version would refuse --- an absolute directory ---
      # still loads and saves. A row written before the rule, or by an older
      # release, is one to notice rather than one a stop cannot get past.
      refused = %{"directory" => "/etc", "command" => "run", "readiness_path" => "/"}
      assert {:error, %Ecto.Changeset{}} = parse(refused)
      assert {:ok, %Config{directory: "/etc"}} = Type.cast(refused)
      assert {:ok, %Config{directory: "/etc"}} = Type.load(refused)
    end

    test "a struct round-trips through the pair without changing" do
      assert {:ok, stored} = Type.dump(@config)
      assert Type.load(stored) == {:ok, @config}
    end
  end
end
