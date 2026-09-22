defmodule Ravix.Tooling.Mutations do
  @moduledoc "Durable mutation claims shared by authenticated browser and protocol actions."
  alias Ravix.Tooling.{Receipt, Store, Tasks}
  # A committed claim precedes external side effects. If the process dies after
  # provider acceptance, retries report uncertainty rather than provisioning twice.
  def run(p, name, args, fun) do
    id = Tasks.digest({p.user.id, p.grant.client_id, name, args["request_id"]})
    fingerprint = Tasks.digest(args)

    row = %Receipt{
      id: id,
      user_id: p.user.id,
      client_id: p.grant.client_id,
      operation: name,
      fingerprint: fingerprint
    }

    # ownership: caller established the operation's Access door before claiming.
    case Store.claim_receipt(row) do
      {:new, saved} ->
        case fun.() do
          {:ok, result} ->
            Store.update(saved, result: json_map(result))
            {:ok, result}

          error ->
            error
        end

      {:existing, %Receipt{fingerprint: ^fingerprint, result: result}} when is_map(result) ->
        {:ok, result}

      {:existing, %Receipt{fingerprint: ^fingerprint}} ->
        {:error,
         {:conflict, "operation_unconfirmed",
          "This operation is in progress or its outcome is unconfirmed. Inspect the project before retrying with a new ID."}}

      _ ->
        {:error, {:conflict, "request_id_used", "This request ID already names different work."}}
    end
  end

  defp json_map(value), do: value |> Jason.encode!() |> Jason.decode!()
end
