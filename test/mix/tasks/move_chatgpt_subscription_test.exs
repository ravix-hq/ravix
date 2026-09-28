defmodule Mix.Tasks.Ravix.MoveChatgptSubscriptionTest do
  @moduledoc """
  The operator's door onto `Ravix.Accounts.Inference.move_subscription/3`: the
  arguments it insists on, whose name the move is made in, and what it prints.

  The move itself is `Ravix.Accounts.InferenceMoveTest`'s. Here the context is
  stubbed at its boundary, because what this task can get wrong is which three
  ids it passes and whether it says anything useful when the answer is no.

  Not async: `Mix.shell/1` is global, and so is who counts as an operator.
  """
  use Ravix.DataCase, async: false
  use Mimic

  alias Mix.Tasks.Ravix.MoveChatgptSubscription, as: Task
  alias Ravix.Accounts.Inference

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    %{operator: insert_user(), from: insert_user(), to: insert_user(login: "dana")}
  end

  test "three ids, or it says which three", _ctx do
    reject(&Inference.move_subscription_as/3)

    for argv <- [[], ["one"], ["one", "two"], ["one", "two", "three", "four"]] do
      assert_raise Mix.Error, ~r/OPERATOR_ID FROM_ID TO_ID/, fn -> Task.run(argv) end
    end
  end

  test "an operator nobody here knows is refused by the context, not looked up here", ctx do
    assert_raise Mix.Error, ~r/nobody to move a ChatGPT subscription as/, fn ->
      Task.run(["ghost", ctx.from.id, ctx.to.id])
    end
  end

  test "the move is made in the named operator's name, and the target is named back", ctx do
    expect(Inference, :move_subscription_as, fn operator_id, from_id, to_id ->
      assert operator_id == ctx.operator.id
      assert from_id == ctx.from.id
      assert to_id == ctx.to.id
      {:ok, ctx.to}
    end)

    Task.run([ctx.operator.id, ctx.from.id, ctx.to.id])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ ctx.to.id
    assert message =~ "@dana"
  end

  test "a refusal is the task's failure, in the words the context used", ctx do
    expect(Inference, :move_subscription_as, fn _, _, _ ->
      {:error, {:forbidden, "Only an operator of this Ravix may move a ChatGPT subscription."}}
    end)

    assert_raise Mix.Error, ~r/Only an operator of this Ravix/, fn ->
      Task.run([ctx.operator.id, ctx.from.id, ctx.to.id])
    end
  end

  test "somebody the context cannot find is a refusal that names what was missing", ctx do
    expect(Inference, :move_subscription_as, fn _, _, _ -> {:error, :not_found} end)

    assert_raise Mix.Error, ~r/No such user/, fn ->
      Task.run([ctx.operator.id, ctx.from.id, "nobody"])
    end
  end
end
