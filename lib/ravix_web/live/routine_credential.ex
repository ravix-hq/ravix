defmodule RavixWeb.Live.RoutineCredential do
  @moduledoc "Transient one-time display; socket inspection must never reveal the bearer credential."
  @derive {Inspect, except: [:value]}
  defstruct [:value]
end
