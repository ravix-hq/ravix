defmodule Ravix.Projects.Sections.Store do
  @moduledoc """
  The section rows, with nobody's permission established: the one batch
  function `Ravix.Workspaces.Backfill` drives after every migration
  (RAV-127). `Ravix.Projects.Sections` holds the scoped readers and
  writers. Nothing here is reachable from a page.
  """

  import Ecto.Query

  alias Ravix.Projects.{Project, Section, SectionPlacement}
  alias Ravix.Repo

  @doc """
  Give up to `limit` sections written without a workspace -- by the release
  before this one, during the deploy or before it -- the workspace of the
  projects placed in them. Returns how many sections were settled.

  A placed project belongs to its own workspace when the section's owner
  is a live member there, and otherwise to that person's personal
  workspace: a project with no workspace yet, and one somebody shared from
  a workspace the person is not in, both sit in the personal sidebar
  (`Ravix.Workspaces.partition/4`). A section whose placements span
  several workspaces is split into one same-named copy per workspace,
  `collapsed` and all, with each placement repointed to the copy of its
  workspace. A section with no placements goes to the personal workspace.

  When the workspace already holds a same-named section of the person's --
  this release created it while the previous one wrote the row being
  settled -- the placements join that one and no duplicate is left behind.

  Selects only rows still without a workspace, for owners the
  personal-workspace backfill has reached, under `FOR UPDATE SKIP LOCKED`:
  a second run, or one on another instance at the same moment, settles
  the remainder and never the same row twice.
  """
  @spec scope_sections(pos_integer()) :: non_neg_integer()
  def scope_sections(limit) do
    # ownership: no door -- the release-time backfill, which runs as no user.
    sections =
      Repo.all(
        from s in Section,
          as: :section,
          where: is_nil(s.workspace_id),
          where:
            exists(
              from w in Ravix.Workspaces.Workspace,
                where:
                  w.personal_user_id == parent_as(:section).user_id and w.kind == :personal and
                    is_nil(w.archived_at),
                select: 1
            ),
          order_by: s.id,
          limit: ^limit,
          lock: "FOR UPDATE SKIP LOCKED"
      )

    user_ids = sections |> Enum.map(& &1.user_id) |> Enum.uniq()

    # ownership: no door -- as above; each owner's personal workspace.
    personal =
      Repo.all(
        from w in Ravix.Workspaces.Workspace,
          where:
            w.personal_user_id in ^user_ids and w.kind == :personal and is_nil(w.archived_at),
          select: {w.personal_user_id, w.id}
      )
      |> Map.new()

    Enum.each(sections, &settle(&1, Map.fetch!(personal, &1.user_id)))
    length(sections)
  end

  defp settle(%Section{id: id, user_id: user_id} = section, personal) do
    # ownership: no door -- as above; where each placed project belongs to
    # this person: its workspace when they are a live member there.
    placed =
      Repo.all(
        from p in SectionPlacement,
          join: pr in Project,
          on: pr.id == p.project_id,
          left_join: w in Ravix.Workspaces.Workspace,
          on: w.id == pr.workspace_id and is_nil(w.archived_at),
          left_join: m in Ravix.Workspaces.Membership,
          on: m.workspace_id == w.id and m.user_id == p.user_id and is_nil(m.revoked_at),
          where: p.section_id == ^id and p.user_id == ^user_id,
          select: {p.project_id, pr.workspace_id, not is_nil(m.user_id)}
      )

    by_workspace =
      Enum.group_by(
        placed,
        fn {_project, workspace, member?} -> if member?, do: workspace, else: personal end,
        fn {project, _workspace, _member?} -> project end
      )

    claimed =
      Enum.reduce(targets(by_workspace, personal), false, fn workspace, claimed ->
        settle_in(section, workspace, Map.get(by_workspace, workspace, []), claimed)
      end)

    # Every placement joined a section that already existed: nothing left.
    unless claimed, do: Repo.delete!(section)
  end

  # The personal workspace first, so a section of only legacy and shared
  # projects keeps its row rather than a copy.
  defp targets(by_workspace, personal) do
    case by_workspace |> Map.keys() |> Enum.sort_by(&{&1 != personal, &1}) do
      [] -> [personal]
      targets -> targets
    end
  end

  # One target workspace: its placements join a same-named section already
  # there; failing that the row itself is claimed for the first workspace,
  # and every later one gets a copy. Returns whether the row is claimed.
  defp settle_in(section, workspace, projects, claimed) do
    case same_named(section, workspace) do
      %Section{id: target} ->
        repoint(section.id, projects, target)
        claimed

      nil when claimed ->
        copy =
          %Section{user_id: section.user_id, workspace_id: workspace}
          |> Section.changeset(%{name: section.name, collapsed: section.collapsed})
          |> Repo.insert!()

        repoint(section.id, projects, copy.id)
        claimed

      nil ->
        section |> Ecto.Changeset.change(workspace_id: workspace) |> Repo.update!()
        true
    end
  end

  defp same_named(%Section{user_id: user_id, name: name}, workspace) do
    Repo.one(
      from s in Section,
        where: s.user_id == ^user_id and s.workspace_id == ^workspace and s.name == ^name
    )
  end

  defp repoint(_from, [], _to), do: :ok

  defp repoint(from, projects, to) do
    Repo.update_all(
      from(p in SectionPlacement, where: p.section_id == ^from and p.project_id in ^projects),
      set: [section_id: to]
    )

    :ok
  end
end
