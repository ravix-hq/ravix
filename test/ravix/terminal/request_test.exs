defmodule Ravix.Terminal.RequestTest do
  use ExUnit.Case, async: true

  alias Ravix.Terminal.Request

  defp parse(attrs), do: Request.parse(attrs)

  test "either spelling of the keys arrives" do
    atoms = %{command: "ls -la", cwd: "src", timeout_sec: 30}
    strings = %{"command" => "ls -la", "cwd" => "src", "timeout_sec" => 30}

    assert parse(atoms) == parse(strings)
    assert {:ok, %Request{command: "ls -la", cwd: "src", timeout_sec: 30}} = parse(atoms)
  end

  test "a request already parsed passes straight through" do
    request = %Request{command: "ls", cwd: nil, timeout_sec: 60}
    assert {:ok, ^request} = parse(request)
  end

  # Both of these are clamped rather than refused, because neither is somebody
  # making a mistake: a browser can send a long paste, and an old client can
  # send a number this version no longer allows.
  test "a command longer than the cap is truncated, not refused" do
    long = String.duplicate("x", Request.max_command_chars() + 500)
    assert {:ok, %Request{command: command}} = parse(%{command: long})
    assert String.length(command) == Request.max_command_chars()
  end

  test "a timeout outside the range is pulled to the nearest end" do
    ceiling = Request.max_timeout_sec()
    assert {:ok, %Request{timeout_sec: ^ceiling}} = parse(%{command: "ls", timeout_sec: 9_999})
    assert {:ok, %Request{timeout_sec: 1}} = parse(%{command: "ls", timeout_sec: 0})
    assert {:ok, %Request{timeout_sec: 1}} = parse(%{command: "ls", timeout_sec: -5})
  end

  test "a timeout nobody sent, or one that is not a number, is the default" do
    default = Request.default_timeout_sec()
    assert {:ok, %Request{timeout_sec: ^default}} = parse(%{command: "ls"})
    assert {:ok, %Request{timeout_sec: ^default}} = parse(%{command: "ls", timeout_sec: "nope"})
    assert {:ok, %Request{timeout_sec: ^default}} = parse(%{command: "ls", timeout_sec: nil})

    # A number that arrived as a string still counts; `cast/4` reads it.
    assert {:ok, %Request{timeout_sec: 5}} = parse(%{command: "ls", timeout_sec: "5"})
  end

  test "an empty command is the one refusal" do
    for command <- ["", "   ", "\n\t", nil] do
      assert {:error, %Ecto.Changeset{errors: [command: {"Type a command.", _}]}} =
               parse(%{command: command}),
             "accepted #{inspect(command)}"
    end

    assert {:error, %Ecto.Changeset{}} = parse(%{})
    assert {:error, %Ecto.Changeset{}} = parse("not a request")
  end

  test "cwd is carried through untouched, because pinning it is the caller's job" do
    # `Ravix.Sprites.resolve_cwd/2` is what confines it to the worktree, and
    # it needs the track's workdir, which this does not have.
    assert {:ok, %Request{cwd: "../../.."}} = parse(%{command: "ls", cwd: "../../.."})
    assert {:ok, %Request{cwd: nil}} = parse(%{command: "ls"})
  end
end
