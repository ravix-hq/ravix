defmodule Ravix.TracksBoot do
  @moduledoc "Checks that the application owns the shared processes used by track tests."

  def ensure_running do
    for name <- [
          Ravix.MachineCache,
          Ravix.Presence,
          Ravix.Tracks.Follower.Supervisor
        ] do
      unless Process.whereis(name), do: raise("#{inspect(name)} is not running")
    end

    :ok
  end
end
