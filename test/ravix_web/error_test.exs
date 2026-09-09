defmodule RavixWeb.ErrorTest do
  use ExUnit.Case, async: true
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
  end

  test "JSON errors halt the connection with a stable public envelope" do
    conn = Error.send_json(Plug.Test.conn(:get, "/"), {:conflict, "busy", "Try again"})
    assert conn.halted
    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"error" => "busy", "message" => "Try again"}
  end
end
