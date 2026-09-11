defmodule Ravix.Accounts.ProjectAccess do
  @moduledoc """
  What `Ravix.Accounts.Access.project_access/2` answers: the project, and the
  capacity the caller reaches it in.

  A struct rather than the anonymous map it was. This is the app's
  *authorization* result -- the thing every context function reads before it
  touches a row -- so it is the last shape that should be structural. A
  `%{project: p}` pattern is satisfied by any map with that key, and a door
  that answered without a `role` would have read as `nil`, which
  `Ravix.Accounts.Access.require_owner/2` refuses; `@enforce_keys` makes it a
  build error at the door instead.

  Every existing reader keeps working: a map pattern matches a struct, so
  `%{project: project, role: role}` at 69 call sites is unchanged. What
  changes is that nothing else can now *satisfy* one by accident.
  """

  alias Ravix.Accounts.Access
  alias Ravix.Projects.Project

  @enforce_keys [:project, :role]
  defstruct [:project, :role]

  @type t :: %__MODULE__{project: Project.t(), role: Access.role()}
end
