defmodule Mix.Tasks.Ravix.MoveChatgptSubscription do
  @moduledoc """
  Move a ChatGPT subscription from one Ravix person to another.

      mix ravix.move_chatgpt_subscription OPERATOR_USER_ID FROM_USER_ID TO_USER_ID

  All three are Ravix user ids. The operator is named so the move is
  authorized and logged as somebody's: they must be in
  `RAVIX_ADMIN_GITHUB_IDS` (`Ravix.Config.admin?/1`), and anybody else is
  refused however the task is run.

  Requires the application's configured database and Fountain connection. The
  writes it makes and what a half-finished one leaves behind are described on
  `Ravix.Accounts.Inference.move_subscription/3`. Nothing here reads or prints
  a credential.
  """
  use Mix.Task

  alias Ravix.Accounts.Inference

  @shortdoc "Move a ChatGPT subscription between Ravix users, as an operator"

  @impl true
  def run([operator_id, from_id, to_id]) do
    Mix.Task.run("app.start")

    case Inference.move_subscription_as(operator_id, from_id, to_id) do
      {:ok, user} ->
        Mix.shell().info("Moved the ChatGPT subscription to #{user.id} (@#{user.login})")

      {:error, reason} ->
        Mix.raise("Move refused: " <> RavixWeb.Error.from(reason, noun: "user").message)
    end
  end

  def run(_argv),
    do: Mix.raise("Usage: mix ravix.move_chatgpt_subscription OPERATOR_ID FROM_ID TO_ID")
end
