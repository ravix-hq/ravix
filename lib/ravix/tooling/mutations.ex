defmodule Ravix.Tooling.Mutations do
  @moduledoc "Durable mutation claims shared by authenticated browser and protocol actions."
  alias Ravix.Tooling.{Receipt, Store, Tasks}
  # A committed claim precedes external side effects. If the process dies after
  # provider acceptance, retries report uncertainty rather than provisioning twice.
  #
  # `release: true` is for an operation whose errors are all refusals made
  # before any effect: the claim is dropped so the same request_id can be
  # retried once the refusal no longer applies.
  def run(p, name, args, fun, opts \\ []) do
    {id, fingerprint} = keys(p, name, args)

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
        record(saved, fun.(), Keyword.get(opts, :release, false))

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

  defp record(saved, {:ok, result}, _release) do
    Store.update(saved, result: json_map(result))
    {:ok, result}
  end

  defp record(saved, error, true) do
    Store.release_receipt(saved)
    error
  end

  defp record(_saved, error, false), do: error

  @doc """
  The recorded result of this caller's own completed request, or `:none`.
  For an operation that removes the caller's access (closing a track), so a
  retry can be answered before the access check would refuse it. The receipt
  is keyed by the caller's user and client, so nothing of anybody else's is
  reachable through it.
  """
  def replay(p, name, args) do
    {id, fingerprint} = keys(p, name, args)

    # ownership: the receipt id is derived from this principal's own user and client ids.
    case Store.receipt(id) do
      %Receipt{fingerprint: ^fingerprint, result: result} when is_map(result) -> {:ok, result}
      _ -> :none
    end
  end

  defp keys(p, name, args),
    do:
      {Tasks.digest({p.user.id, p.grant.client_id, name, args["request_id"]}), Tasks.digest(args)}

  defp json_map(value), do: value |> Jason.encode!() |> Jason.decode!()
end
