defmodule Ravix.Projects.Machine.Provisioned do
  @moduledoc """
  The three Fountain records a project is, and the harness its agent was made
  with.

  `Ravix.Projects.Machine.provision/2` returns one, and builds it a field at a
  time: it is also the accumulator the four creation steps fold over, so every
  field defaults to nil and "nothing went in yet" is a real value rather than
  a struct that cannot be built. That is why there is no `@enforce_keys` here
  and there is one on `Ravix.Projects.Machine.Harness`.

  `vault_id` stays nil on a Fountain with no vault support (403, 404 or 501
  from `POST /api/vaults`), which is a configuration Ravix must run in, so
  nil there is an answer rather than a half-made project.

  A struct rather than the five-key map it was, because that map was also
  what `unwind/2` took --- alongside a `Ravix.Projects.Project` and alongside
  itself again from `Projects.insert_provisioned/3` --- and the only way to
  declare a parameter that accepts all three was
  `%{optional(:agent_id) => ..., optional(atom()) => term()}`, which declares
  nothing. Two clauses now say what the two shapes are.
  """

  @type t :: %__MODULE__{
          environment_id: String.t() | nil,
          vault_id: String.t() | nil,
          agent_id: String.t() | nil,
          runtime: String.t() | nil,
          model: String.t() | nil
        }

  defstruct environment_id: nil, vault_id: nil, agent_id: nil, runtime: nil, model: nil
end
