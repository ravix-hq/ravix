defmodule Ravix.Changelog do
  @moduledoc "Curated user-facing changes shipped with Ravix."
  @entries [
    %{
      id: "2026-09-26-threads",
      date: ~D[2026-09-26],
      kind: :new,
      title: "Threads per track",
      body: "Keep separate conversations in one track so related work stays easy to follow.",
      action: nil
    },
    %{
      id: "2026-09-24-branch-names",
      date: ~D[2026-09-24],
      kind: :improved,
      title: "Clearer track branches",
      body:
        "Track branches now use the `ravix/` prefix so they are easy to recognize in your repository.",
      action: nil
    },
    %{
      id: "2026-09-23-tooling",
      date: ~D[2026-09-23],
      kind: :new,
      title: "MCP and A2A tooling",
      body:
        "Connect desktop agents to Ravix with MCP or A2A and drive projects from your preferred client.",
      action: "Open Help"
    },
    %{
      id: "2026-09-20-onboarding",
      date: ~D[2026-09-20],
      kind: :new,
      title: "A gentler first visit",
      body:
        "The onboarding walkthrough helps you connect an agent and get your first project ready.",
      action: nil
    },
    %{
      id: "2026-09-18-settings",
      date: ~D[2026-09-18],
      kind: :improved,
      title: "Redesigned settings",
      body:
        "Project settings are grouped into clearer sections, with safer controls for access and setup.",
      action: nil
    },
    %{
      id: "2026-09-15-diff",
      date: ~D[2026-09-15],
      kind: :improved,
      title: "Readable formatted diffs",
      body: "Review changes in a formatted diff view with clearer files and additions.",
      action: nil
    },
    %{
      id: "2026-09-10-notifications",
      date: ~D[2026-09-10],
      kind: :new,
      title: "Desktop notifications",
      body:
        "Get a small notification when a track needs your attention while Ravix is in the background.",
      action: nil
    }
  ]
  @spec all() :: [map()]
  def all, do: @entries
  def since(nil), do: []

  def since(%DateTime{} = seen),
    do: Enum.filter(@entries, &(DateTime.compare(at(&1), seen) == :gt))

  def newest([]), do: nil
  def newest(entries), do: Enum.max_by(entries, & &1.date)

  @doc """
  The moment an entry counts as shipped, in the precision the column holds.

  A date alone is second-precision, which `:utc_datetime_usec` refuses, so
  every comparison and every marker is built here rather than at each caller.
  """
  @spec at(map() | Date.t()) :: DateTime.t()
  def at(%{date: date}), do: at(date)
  def at(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")

  def validate do
    Enum.each(@entries, fn e ->
      unless is_binary(e.id) and e.title != "" and e.body != "" and
               e.kind in [:new, :improved, :fixed] and match?(%Date{}, e.date),
             do: raise("invalid changelog entry")
    end)

    :ok
  end
end
