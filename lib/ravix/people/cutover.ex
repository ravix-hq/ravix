defmodule Ravix.People.Cutover do
  @moduledoc """
  Retire #299's track invitations and links for workspace sharing (ADR 0009
  phase 5, RAV-20), once `RAVIX_WORKSPACE_ACCESS` is on.

  For every track on a workspace project that still holds a legacy seat
  (`Ravix.Tracks.TrackMember`), a waiting invitation or a link:

    * a seat whose holder is a live member of the track's workspace becomes
      a permission row (`Ravix.Tracks.TrackPermission`) and the seat goes.
      Nothing is widened: a permission row admits only while its holder
      stays in the workspace, which is narrower than the seat was.
    * a seat whose holder is not a member is taken away, with its preview
      grants. Nobody is made a workspace member by it, and no legacy grant
      is broadened into one.
    * waiting invitations are withdrawn and the link is deleted, so an old
      link URL admits nobody (`Ravix.People.claim_link/2` also refuses it).
    * whoever lost access, or had an invitation withdrawn, is listed in one
      Inbox note to the track's creator (`Ravix.People.AccessNotice`),
      pointing at the workspace's people page to invite them there.

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

  @type summary :: %{applied: boolean(), tracks: [track_line()]}

  @doc "Work out the cutover, and write it when `apply: true`."
  @spec run(keyword()) :: {:ok, summary()} | {:error, :switch_off}
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)

    if Ravix.Config.workspace_access?() do
      # ownership: no door -- an operator step run as nobody; see the moduledoc.
      lines =
        Enum.map(Store.cutover_tracks(), fn {track, project} -> step(track, project, apply?) end)

      {:ok, %{applied: apply?, tracks: lines}}
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
    creator = track.created_by || project.user_id

    # ownership: no door -- an operator step run as nobody; these rows are
    # the track's own seats and their holders' memberships.
    {converted, gone} =
      track.id
      |> Store.members_of()
      |> Enum.reject(&(&1.id in [creator, project.user_id]))
      |> Enum.split_with(&(Workspaces.membership(workspace_id, &1.id) != nil))

    revoked = Enum.reject(gone, &keeps_it?(&1, track, project))
    withdrawn = Enum.map(Store.invites_of(track.id), & &1.login)

    %{
      track_id: track.id,
      title: track.title,
      project_id: project.id,
      workspace_id: workspace_id,
      converted: Enum.map(converted, & &1.login),
      revoked: Enum.map(revoked, & &1.login),
      withdrawn: withdrawn,
      link: Store.link_of(track.id) != nil,
      # A closed track has nothing left to lose access to, and no page to
      # say so from; its seats and links still go.
      notify: if(is_nil(track.closed_at), do: creator),
      seats: %{convert: Enum.map(converted, & &1.id), remove: Enum.map(gone, & &1.id)}
    }
  end

  # Whether somebody whose seat goes still reaches the track without it:
  # `Access.visible_track?/3` with the switch on, for a non-member of the
  # workspace, admits only a legacy project member, and only to a
  # project-visible track. They keep it and are not listed as losing it.
  defp keeps_it?(user, track, project) do
    # ownership: no door -- an operator step; is this seat their only way in?
    track.visibility == :project and Access.project_member?(project.id, user.id)
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
  def format(%{applied: applied, tracks: tracks}) do
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
        "#{Enum.count(tracks, & &1.link)} link(s) invalidated."
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
      end)
  end

  defp logins([]), do: "none"
  defp logins(list), do: Enum.map_join(list, ", ", &"@#{&1}")
end
