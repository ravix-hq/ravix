defmodule Ravix.Routines.Store do
  @moduledoc "Webhook admission and durable claims. Routine locks serialize claims with edits/rotation."
  import Ecto.Query
  alias Ravix.Accounts.{Access, Store}
  alias Ravix.{Crypto, Repo}
  alias Ravix.Routines.{Dispatch, Routine}

  def claim(id, token, request_id, payload_hash) do
    Repo.transaction(fn ->
      row = Repo.one(from r in Routine, where: r.id == ^id, lock: "FOR UPDATE")
      user = authenticate(row, token)
      if not row.enabled, do: Repo.rollback(:paused)

      case Repo.one(
             from d in Dispatch, where: d.routine_id == ^id and d.request_id == ^request_id
           ) do
        nil ->
          dispatch =
            Repo.insert!(%Dispatch{
              id: Ecto.UUID.generate(),
              routine_id: id,
              request_id: request_id,
              payload_hash: payload_hash
            })

          {:new, row, user, dispatch}

        %{payload_hash: ^payload_hash} = dispatch ->
          {:duplicate, dispatch}

        _ ->
          Repo.rollback(:conflict)
      end
    end)
  end

  defp authenticate(nil, _token), do: Repo.rollback(:unauthorized)

  defp authenticate(row, token) do
    unless Plug.Crypto.secure_compare(row.credential_hash, Crypto.sha256(token)),
      do: Repo.rollback(:unauthorized)

    # ownership: the credential admits only this routine's recorded creator;
    # Access.project_access checks current write membership before any track effect.
    user = Store.get_user(row.user_id)

    unless user && match?({:ok, _}, Access.project_access(user, row.project_id, :write)),
      do: Repo.rollback(:unauthorized)

    user
  end

  def finish(dispatch, status, track_id) do
    Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
      set: [status: status, track_id: track_id, updated_at: DateTime.utc_now()]
    )

    %{dispatch | status: status, track_id: track_id}
  end
end
