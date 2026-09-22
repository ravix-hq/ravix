defmodule RavixWeb.ErrorTest do
  use ExUnit.Case, async: true
  alias Ravix.Previews
  alias Ravix.Terminal.Request
  alias RavixWeb.Error

  test "context refusal shapes preserve their public status and code" do
    for {reason, status, code} <- [
          {:not_found, 404, "not_found"},
          {{:preview_agent_auth, "Expired"}, 401, "preview_agent_auth"},
          {{:preview_unavailable, "Unavailable"}, 501, "preview_unavailable"},
          {:unauthenticated, 401, "unauthenticated"},
          {:session_ended, 401, "unauthenticated"},
          {:reauthenticate, 401, "reauthenticate"},
          {:no_token, 401, "reauthenticate"},
          {{:forbidden, "Owner only"}, 403, "owner_only"},
          {{:conflict, :busy, "Busy"}, 409, "busy"},
          {{:unprocessable, :empty, "Empty"}, 422, "empty"},
          {{:unavailable, :offline, "Offline"}, 503, "offline"},
          {{:unavailable, "Offline"}, 503, "unavailable"}
        ] do
      assert %{status: ^status, code: ^code} = Error.from(reason)
    end

    assert Error.from(:not_found, noun: "project").message == "No such project."
  end

  test "unknown errors hide internal details and typed errors pass through" do
    error = %Error{status: 409, code: "busy", message: "Try again"}
    assert Error.from(error) == error
    assert Error.from({:secret_failure, "password"}) == %Error{}
    assert Error.from(%Ravix.Sprites.Error{status: 0, message: "offline"}).status == 502
    assert Error.from(%Ravix.Sprites.Error{status: 404, message: "missing"}).status == 404
    assert Error.from(:unconfigured).status == 503
    assert Error.from(%Ravix.GitHub.Error{status: 403, message: "denied"}).status >= 400
  end

  test "changeset errors interpolate validation bounds without exposing submitted values" do
    changeset =
      {%{}, %{name: :string}}
      |> Ecto.Changeset.cast(%{name: "a"}, [:name])
      |> Ecto.Changeset.validate_length(:name, min: 3)

    assert Error.from(changeset).message =~ "at least 3"

    assert Error.from(Ecto.Changeset.change({%{}, %{name: :string}})).message ==
             "The request is not valid."

    # Ecto's own messages are fragments and need the field in front of them.
    assert Error.from(changeset).message =~ ~r/^name /
  end

  test "a sentence a context wrote is not relabelled with its own field" do
    # `Ravix.Previews.Config` and `Ravix.Terminal.Request` refuse with the
    # thing to tell somebody. Prefixing one of those gave "command Type a
    # command.." --- the field twice over and two full stops.
    {:error, changeset} = Request.parse(%{command: "   "})
    assert Error.from(changeset).message == "Type a command."

    {:error, changeset} = Previews.parse_config(%{directory: "/etc", command: "x"})
    assert Error.from(changeset).message == "Choose a relative app directory inside this track."
  end

  test "JSON errors halt the connection with a stable public envelope" do
    conn = Error.send_json(Plug.Test.conn(:get, "/"), {:conflict, "busy", "Try again"})
    assert conn.halted
    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"error" => "busy", "message" => "Try again"}
  end

  describe "the vocabulary is closed, and says so when it is not" do
    test "a preview server that stopped mid-operation is a 503, not an internal error" do
      # `Ravix.Previews.Server.run/2` answers this when the process holding a
      # track's preview goes away underneath the call, which reaches a page
      # through `Previews.stop/2` whenever somebody presses Stop at the wrong
      # moment. It had no clause here and rendered as the generic 500.
      error = Error.from(:preview_server_down)

      assert error.status == 503
      assert error.code == "preview_unavailable"
      assert error.message =~ "not running right now"
      refute error.message =~ "went wrong"
    end

    test "every refusal a context can hand a page has a sentence of its own" do
      known = [
        :not_found,
        :unauthenticated,
        :session_ended,
        :reauthenticate,
        :no_token,
        :unconfigured,
        :preview_server_down,
        {:forbidden, "Only the owner can do that."},
        {:conflict, "closed_track", "That track is closed."},
        {:unprocessable, "bad_config", "That configuration is not valid."},
        {:unavailable, "The machine is not up."},
        {:unavailable, "no_github", "No GitHub App is configured."},
        {:preview_agent_auth, "no"},
        {:preview_unavailable, "no"}
      ]

      for reason <- known do
        error = Error.from(reason)

        assert error.status != 500,
               "#{inspect(reason)} falls through to the generic 500"

        refute error.code == "internal", "#{inspect(reason)} falls through to the generic 500"
      end
    end

    test "a task that exited has a sentence, and it says nothing about why" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          error = Error.from({:async_exit, {%RuntimeError{message: "token hunter2"}, []}})
          assert error.code == "async_exit"
          assert error.message == "The operation could not finish. Refresh and try again."
          refute error.message =~ "hunter2"
        end)

      # The task's own crash report already said what happened; this is not
      # a shape nobody planned for.
      refute log =~ "no RavixWeb.Error clause"
    end

    test "a shape nobody wrote a sentence for is still hidden, but no longer silent" do
      # Hiding it is right: a refusal with no clause is one we cannot describe
      # safely. Doing it quietly is what let `:preview_server_down` read as an
      # internal error indefinitely.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %Error{status: 500, code: "internal"} =
                   Error.from({:shape_nobody_planned_for, 1})
        end)

      assert log =~ "no RavixWeb.Error clause"
      assert log =~ "shape_nobody_planned_for"
    end

    test "the log names the shape and never what the refusal was carrying" do
      # The refusal that reaches here carrying a value is the one where the
      # value is a secret somebody failed to write. The tag is what a missing
      # clause needs; the payload is not ours to put in a log file.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Error.from({:secret_failure, "hunter2", %{token: "ghp_live"}})
          Error.from(%URI{host: "internal.example"})
        end)

      assert log =~ "{:secret_failure, _, _}"
      assert log =~ "%URI{}"
      refute log =~ "hunter2"
      refute log =~ "ghp_live"
      refute log =~ "internal.example"
    end
  end

  describe "the contexts' vocabularies are covered" do
    # `@type reason` in each context used to end in `| term()`, so it
    # documented four shapes and then admitted anything. With the escape
    # hatches gone, this walks what the types now declare and holds every
    # member to having a sentence of its own here. A context that grows a new
    # refusal and forgets `RavixWeb.Error` fails at this line rather than in
    # production.
    @vocabularies %{
      Ravix.Previews => [
        :not_found,
        :preview_server_down,
        {:conflict, "closed_track", "That track is closed."},
        {:unprocessable, "preview_config", "Supply a preview configuration."},
        {:unavailable, "Previews are not configured."},
        {:unavailable, "preview_replaced", "Something else took the port."}
      ],
      Ravix.Terminal => [
        :not_found,
        {:conflict, "no_machine", "The workspace is not available."},
        {:unprocessable, "empty_command", "Type a command."},
        {:unavailable, "no_exec", "No Sprites token."},
        %Ravix.Sprites.Error{status: 502, message: "offline"}
      ],
      Ravix.Tracks => [
        :not_found,
        :unconfigured,
        {:forbidden, "Only the owner can do that."},
        {:conflict, "closed_track", "That track is closed."},
        {:unprocessable, "bad_origin", "That origin is not one of the four."},
        {:unavailable, "no_fountain", "No Fountain account is configured."},
        %Ravix.Fountain.Error{status: 502, code: "bad_gateway", message: "no", kind: :http},
        %Ravix.GitHub.Error{status: 403, message: "denied"}
      ]
    }

    test "every refusal each context declares has a sentence, and none is the generic 500" do
      # The catch-all is the only clause that answers `internal`, so the code
      # is the whole of the check. It used to also refute its warning in a
      # log capture, but a capture sees every process, and the suites that
      # deliberately reach the catch-all with shapes of their own run
      # alongside this one.
      for {context, reasons} <- @vocabularies, reason <- reasons do
        error = Error.from(reason)

        refute error.code == "internal",
               "#{inspect(context)} can return #{inspect(reason)} and it falls through to 500"

        assert error.message != "",
               "#{inspect(context)} can return #{inspect(reason)} with no sentence"
      end
    end

    test "the escape hatches are gone and stay gone" do
      # The point of the exercise: a context cannot quietly widen its refusals
      # again without this failing.
      for path <- ~w(lib/ravix/previews.ex lib/ravix/terminal.ex lib/ravix/tracks.ex) do
        source = File.read!(path)
        [_, reason_type] = Regex.run(~r/@type reason ::(.*?)\n\n/s, source)

        refute reason_type =~ "term()",
               "#{path} admits any term as a refusal again; every one needs a clause in " <>
                 "RavixWeb.Error.from/2, and `| term()` is how that stops being checkable."
      end
    end
  end
end
