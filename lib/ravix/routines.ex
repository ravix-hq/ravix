defmodule Ravix.Routines do
  @moduledoc "Personal webhook routines scoped through current project write access."
  import Ecto.Query
  alias Ravix.Accounts.{Access, User}
  alias Ravix.{Crypto, Repo}
  alias Ravix.Routines.{Dispatch, Routine}

  def list(%User{id: id} = user) do
    Repo.all(from r in Routine, where: r.user_id == ^id, order_by: [desc: r.inserted_at])
    |> Enum.filter(&match?({:ok, _}, Access.project_access(user, &1.project_id, :write)))
  end

  def create(%User{} = user, project_id, attrs) do
    with {:ok, _} <- Access.project_access(user, project_id, :write) do
      token = Crypto.random_token()

      case %Routine{
             user_id: user.id,
             project_id: project_id,
             credential_hash: Crypto.sha256(token)
           }
           |> Routine.changeset(attrs)
           |> Repo.insert() do
        {:ok, row} -> {:ok, row, token}
        error -> error
      end
    end
  end

  def get(%User{id: user_id} = user, id) when is_binary(id) do
    with %Routine{} = row <-
           Repo.one(from r in Routine, where: r.id == ^id and r.user_id == ^user_id),
         {:ok, _} <- Access.project_access(user, row.project_id, :write) do
      {:ok, row}
    else
      _ -> {:error, :not_found}
    end
  end

  def get(_user, _id), do: {:error, :not_found}

  def update(user, id, attrs) do
    with {:ok, row} <- get(user, id), do: row |> Routine.changeset(attrs) |> Repo.update()
  end

  def delete(user, id) do
    with {:ok, row} <- get(user, id), do: Repo.delete(row)
  end

  def rotate(user, id) do
    with {:ok, row} <- get(user, id) do
      token = Crypto.random_token()

      case row |> Ecto.Changeset.change(credential_hash: Crypto.sha256(token)) |> Repo.update() do
        {:ok, row} -> {:ok, row, token}
        error -> error
      end
    end
  end

  def history(user, id) do
    with {:ok, _} <- get(user, id) do
      {:ok,
       Repo.all(
         from d in Dispatch,
           where: d.routine_id == ^id,
           order_by: [desc: d.inserted_at],
           limit: 20
       )}
    end
  end

  @doc "Webhook boundary: credentials and creator access are checked by the runner before claiming."
  defdelegate receive(id, credential, request_id, event), to: Ravix.Routines.Runner
end
