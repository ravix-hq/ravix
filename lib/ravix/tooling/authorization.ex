defmodule Ravix.Tooling.Authorization do
  @moduledoc "Authenticated person actions from OAuth or the browser session. Agent credentials plug in separately."
  alias Ravix.{Accounts, Tooling}

  def browser(user, session_hash),
    do: %{user: user, session_hash: session_hash, actor: :person, grant: %{client_id: nil}}

  def check(%{session_hash: hash, user: %{id: id}} = principal, _scope) do
    case Accounts.open_session(hash) do
      {:ok, %{id: ^id} = user, _} -> {:ok, %{principal | user: user}}
      _ -> {:error, :unauthenticated}
    end
  end

  def check(principal, scope), do: Tooling.OAuth.check(principal, scope)

  def person(%{actor: {:track_agent, _}}),
    do: {:error, {:forbidden, "Only people can assign plan items."}}

  def person(_), do: :ok
end
