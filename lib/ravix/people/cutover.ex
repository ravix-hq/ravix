defmodule Ravix.People.Cutover do
  @moduledoc """
  Retire #299's track invitations and links for workspace sharing (ADR 0009
  phase 5, RAV-20), once `RAVIX_WORKSPACE_ACCESS` is on.

  For every track on a workspace project that still holds a legacy seat
  (`Ravix.Tracks.TrackMember`), a waiting invitation or a link:

    * every seat goes, the project owner's and the creator's included.
    * on a private track, a seat whose holder is a live member of the
      track's workspace (and not its creator) becomes a permission row
      (`Ravix.Tracks.TrackPermission`). Nothing is widened: the row admits
      only while its holder stays in the workspace, which is narrower than
      the seat was. A project-visible track gets no rows: its members
      reach it through the workspace already.
    * any other seat is taken away, with its preview grants. Nobody is made
      a workspace member by it, and no legacy grant is broadened into one.
    * waiting invitations are withdrawn and the link is deleted, so an old
      link URL admits nobody (`Ravix.People.claim_link/2` also refuses it).
    * whoever lost access, or had an invitation withdrawn, is listed in one
      Inbox note to the track's creator (`Ravix.People.AccessNotice`),
      pointing at the workspace's people page to invite them there.

  Projects in a **personal** workspace are skipped and reported, seats,
  invitations and links untouched. A personal workspace has no other members,
  so there a seat or a legacy project membership is the only way anybody
  but its owner reaches the project: the one-time move of legacy projects
  into their owners' personal workspaces
  (`Ravix.Workspaces.PersonalAssignment`) keeps them, and a cutover run
  after it must not take them away. They are retired when the owner moves
  the project into a team workspace and the cutover runs again.

  Somebody is listed as having lost access only if they no longer reach
  the track at all -- a legacy project member on a project-visible track
  keeps it through the project, and is not.

  A dry run by default: `run(apply: false)` works out and returns the plan
  and writes nothing. `run(apply: true)` writes it track by track, each
  step idempotent, and tells that project's open pages. Running it again finds
  nothing left to do and writes nothing, the notes included. Refused while
  the switch is off, when these tracks still work the legacy way.

  An operator step, run as no user: there is no door, which is why every
  row it touches goes through `Ravix.People.Store`.
  """

  alias Ravix.Accounts.Access
  alias Ravix.People.Store
  alias Ravix.Workspaces.Store, as: Workspaces

  @type track_line :: %{
          track_id: String.t(),
          title: String.t(),
          project_id: String.t(),
          workspace_id: String.t(),
          converted: [String.t()],
          revoked: [String.t()],
          withdrawn: [String.t()],
          link: boolean(),
          notify: String.t() | nil,
          seats: %{convert: [String.t()], remove: [String.t()]}
        }

  @type skipped_line :: %{track_id: String.t(), title: String.t(), project_id: String.t()}

  @type summary :: %{applied: boolean(), tracks: [track_line()], skipped: [skipped_line()]}

  @doc "Work out the cutover, and write it when `apply: true`."
  @spec run(keyword()) :: {:ok, summary()} | {:error, :switch_off}
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)

    if Ravix.Config.workspace_access?() do
      # ownership: no door -- an operator step run as nobody; see the moduledoc.
      candidates = Store.cutover_tracks()
      personal = Workspaces.personal_ids(Enum.map(candidates, &elem(&1, 1).workspace_id))

      {skipped, retired} =
        Enum.split_with(candidates, fn {_track, project} ->
          MapSet.member?(personal, project.workspace_id)
        end)

      lines = Enum.map(retired, fn {track, project} -> step(track, project, apply?) end)

      skipped =
        Enum.map(skipped, fn {track, project} ->
          %{track_id: track.id, title: track.title, project_id: project.id}
        end)

      {:ok, %{applied: apply?, tracks: lines, skipped: skipped}}
    else
      {:error, :switch_off}
    end
  end

  defp step(track, project, apply?) do
    line = plan(track, project)
    if apply?, do: write(line, track, project)
    line
  end

  defp plan(track, project) do
    workspace_id = project.workspace_id
    notify = track.created_by || project.user_id

    # ownership: no door -- an operator step run as nobody; these rows are
    # the track's own seats and their holders' memberships.
    seats =
      Enum.map(Store.members_of(track.id), fn user ->
        {user, Workspaces.membership(workspace_id, user.id) != nil}
      end)

    # Every seat goes, the owner's and the creator's included: with the
    # switch on a seat admits whatever the workspace says, so one left
    # behind would outlive its holder's membership. Only a live member on a
    # private track, other than its creator, becomes a permission row; on a
    # project-visible track a row would turn into a grant the creator never
    # chose the day they made it private, and the creator needs none.
    {converted, removed} =
      Enum.split_with(seats, fn {user, member?} ->
        member? and track.visibility == :private and user.id != track.created_by
      end)

    revoked =
      for {user, member?} <- removed,
          user.id != notify,
          not keeps_it?(user, member?, track, project),
          do: user

    %{
      track_id: track.id,
      title: track.title,
      project_id: project.id,
      workspace_id: workspace_id,
      converted: Enum.map(converted, &elem(&1, 0).login),
      revoked: Enum.map(revoked, & &1.login),
      withdrawn: Enum.map(Store.invites_of(track.id), & &1.login),
      link: Store.link_of(track.id) != nil,
      # A closed track has nothing left to lose access to, and no page to
      # say so from; its seats and links still go.
      notify: if(is_nil(track.closed_at), do: notify),
      seats: %{
        convert: Enum.map(converted, &elem(&1, 0).id),
        remove: Enum.map(removed, &elem(&1, 0).id)
      }
    }
  end

  # Whether somebody whose seat goes still reaches the track without it, as
  # `Access.visible_track?/3` decides with the switch on: a project-visible
  # track is still theirs through the workspace, or through a legacy grant
  # (the project's owner, a project member). A private one is not, since
  # the only non-creator way in is the permission row they did not get.
  defp keeps_it?(user, member?, track, project) do
    # ownership: no door -- an operator step; is this seat their only way in?
    track.visibility == :project and
      (member? or user.id == project.user_id or Access.project_member?(project.id, user.id))
  end

  # Resumable rather than one transaction: every step is idempotent, and the
  # note goes first, so a run that stops part-way and is started again finds
  # the same people and writes no second note. A holder removed from the
  # workspace between the plan and the write gets no permission row
  # (`add_permission/4` re-reads the membership under lock); their seat goes
  # either way.
  defp write(line, track, project) do
    if line.notify && (line.revoked != [] or line.withdrawn != []) do
      Store.put_notice(%{
        track_id: track.id,
        user_id: line.notify,
        workspace_id: line.workspace_id,
        revoked_logins: line.revoked,
        withdrawn_logins: line.withdrawn
      })
    end

    for id <- line.seats.convert do
      _ = Store.add_permission(track.id, id, line.workspace_id, line.notify)
      Store.remove_member(track.id, id)
    end

    for id <- line.seats.remove, do: Store.remove_member(track.id, id)
    Store.drop_invites(track.id)
    Store.drop_link(track.id)
    Ravix.Hub.publish(project.id, :people, track_id: track.id)
  end

  @doc "The summary as lines to print: ids, titles and logins, no secrets."
  @spec format(summary()) :: [String.t()]
  def format(%{applied: applied, tracks: tracks} = summary) do
    skipped = Map.get(summary, :skipped, [])
    count = fn key -> tracks |> Enum.map(&length(Map.fetch!(&1, key))) |> Enum.sum() end

    header = [
      if(applied,
        do: "Applied.",
        else: "Dry run: nothing was written. Pass --apply to write it."
      ),
      "#{length(tracks)} track(s) with invitations, links or seats to retire.",
      "#{count.(:converted)} seat(s) become permission rows; " <>
        "#{count.(:revoked)} person(s) lose access; " <>
        "#{count.(:withdrawn)} waiting invitation(s) withdrawn; " <>
        "#{Enum.count(tracks, & &1.link)} link(s) invalidated.",
      "#{length(skipped)} track(s) on projects in a personal workspace left as they are."
    ]

    header ++
      Enum.map(tracks, fn t ->
        "  #{t.track_id} #{inspect(t.title)}: " <>
          Enum.join(
            [
              "converted #{logins(t.converted)}",
              "revoked #{logins(t.revoked)}",
              "withdrawn #{logins(t.withdrawn)}",
              if(t.link, do: "link dropped", else: "no link")
            ],
            "; "
          )
      end) ++
      Enum.map(skipped, fn t ->
        "  #{t.track_id} #{inspect(t.title)}: skipped, project #{t.project_id} is in a " <>
          "personal workspace; seats and project members kept"
      end)
  end

  defp logins([]), do: "none"
  defp logins(list), do: Enum.map_join(list, ", ", &"@#{&1}")
end
