defmodule RavixWeb.Live.ResultTest do
  @moduledoc """
  Both pages now share one reading of a context's answer, so it is worth
  saying here what that reading is rather than inferring it from whichever
  page happens to be under test.
  """
  use ExUnit.Case, async: true

  import RavixWeb.Live.Result

  defp socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  test "a bare :ok runs the success branch with no value" do
    assert result(socket(), :ok, fn _s, value -> {:ran, value} end) == {:ran, nil}
  end

  test "{:ok, value} runs it with the value" do
    assert result(socket(), {:ok, [1, 2]}, fn _s, value -> {:ran, value} end) == {:ran, [1, 2]}
  end

  test "a refusal never reaches the success branch, and flashes the reason's own sentence" do
    socket =
      result(socket(), {:error, {:forbidden, "Only the owner can do that."}}, fn _, _ ->
        flunk("the success branch ran on an error")
      end)

    assert socket.assigns.flash == %{"error" => "Only the owner can do that."}
  end

  test "a reason with no sentence of its own still says something" do
    socket = error(socket(), :not_found)
    assert socket.assigns.flash == %{"error" => "No such thing here."}
  end

  test "an unrecognised reason does not crash the page" do
    socket = error(socket(), {:some_shape_nobody_planned_for, 42})
    assert socket.assigns.flash["error"] =~ "Something went wrong"
  end

  test "work that exited says the one sentence for it, whatever it exited with" do
    for reason <- [:killed, {%RuntimeError{message: "provider fell over"}, []}] do
      socket = exit(socket(), reason)

      assert socket.assigns.flash == %{
               "error" => "The operation could not finish. Refresh and try again."
             }
    end
  end

  test "a component hands the sentence to its page rather than a socket nobody renders" do
    component = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, myself: %Phoenix.LiveComponent.CID{cid: 1}}
    }

    assert exit(component, :killed) == component
    assert_received {:flash, :error, "The operation could not finish. Refresh and try again."}

    assert flash(component, :info, "Saved.") == component
    assert_received {:flash, :info, "Saved."}

    assert error(component, :not_found) == component
    assert_received {:flash, :error, "No such thing here."}
  end
end
