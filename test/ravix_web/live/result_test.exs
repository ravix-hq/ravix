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

  describe "where a flash goes" do
    test "a component hands the sentence to its own process, and puts nothing itself" do
      component = %{
        socket()
        | assigns: Map.put(socket().assigns, :myself, %Phoenix.LiveComponent.CID{cid: 1})
      }

      assert flash(component, :error, "No.").assigns.flash == %{}
      assert_receive {:flash, :error, "No."}
      refute_receive {:clear_flash, _, _}, 10
    end

    test "a nested LiveView hands it to the page above, whatever the kind" do
      nested = %{socket() | parent_pid: self()}
      assert flash(nested, :info, "Saved.").assigns.flash == %{}
      assert_receive {:flash, :info, "Saved."}
      refute_receive {:clear_flash, _, _}, 10
    end

    test "a page puts a notice and arranges to let it go; an error it keeps" do
      socket = flash(socket(), :info, "Saved.", after: 0)
      assert socket.assigns.flash == %{"info" => "Saved."}
      assert_receive {:clear_flash, :info, "Saved."}

      socket = flash(socket(), :error, "Could not save.", after: 0)
      assert socket.assigns.flash == %{"error" => "Could not save."}
      refute_receive {:clear_flash, _, _}, 10
      assert notice_ms() == 6_000
    end

    test "the clear takes only the sentence it was set for" do
      socket = flash(socket(), :info, "Second.", after: 0)
      assert clear_notice(socket, :info, "First.").assigns.flash == %{"info" => "Second."}
      assert clear_notice(socket, :info, "Second.").assigns.flash == %{}
    end
  end
end
