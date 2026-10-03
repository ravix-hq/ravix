defmodule Ravix.Accounts.Access do
  @moduledoc """
  Who is asking, and what they are allowed to touch.

  Shorter than paddock's equivalent, and the difference is worth naming:
  paddock admits people with no account at all, so identity there is a union
  and every route downstream has to handle both halves. Ravix has one kind
  of caller, somebody signed in with GitHub, and three doors, in widening
  order:

      track_access/2    one branch, because you were named on it
      project_access/2  every branch on a machine, because you were named on it
      project_of/2      the machine itself, because you own it

  and one question beside them, `access_of/3`, which says *which* of the
  three a person would get through for a project already in hand: what the
  rail marks each project with.

  All three are enforced by lookup rather than by a check, and all three
  answer *not found* rather than refusing: the existence of somebody else's
  project is not the caller's to learn. Every context function that touches
  a project or a track goes through one of these first; the `_unsafe_`
  functions elsewhere are only ever called beside a door that already
  answered.

  The port of `server/context.ts`, with the HTTP taken out: the doors return
  `{:ok, ...} | {:error, :not_found}` and the two `require_*` guards return
  `:ok | {:error, {:forbidden, message}}`; `RavixWeb.Error` turns those back
  into the 404 and 403 the TypeScript threw.
  """

  require Ecto.Query

  alias Ravix.Accounts.{ProjectAccess, TrackAccess, User}
  alias Ravix.People.Store, as: People
  alias Ravix.Projects.Project
  alias Ravix.Projects.Store, as: Projects
  alias Ravix.Repo
  alias Ravix.Tracks.Track

  @typedoc "Owner, or somebody invited to the track or the project in question."
  @type role :: :owner | :member

  @typedoc """
  What somebody may do once they are in (ADR 0010), widening: `:read` sees
  the transcript, files and preview; `:write` also prompts, runs commands
  and uses the machine; `:admin` also manages the people. `role` above says
  how somebody got in; this says what they may do there.
  """
  @type level :: :read | :write | :admin

  @levels [:read, :write, :admin]

  @typedoc "Which of the three ways in reaches a project. See `access_of/3`."
  @type access :: :owner | :project | :tracks

  @typedoc """
  Membership a caller has already read, so `access_of/3` need not read it again.

  `:projects` is the set of project ids this person was let into whole;
  `:workspaces` the ids of live workspaces they are a live member of;
  `:tracks` is the set of project ids they hold an open track on, or the
  track rows themselves. A key left out is read from the database for the
  one project asked about.
  """
  @type known :: [
          {:projects, MapSet.t(String.t())}
          | {:workspaces, MapSet.t(String.t())}
          | {:tracks, MapSet.t(String.t()) | [Track.t()]}
        ]

  @typedoc "What `project_access/2` answers. See `Ravix.Accounts.ProjectAccess`."
  @type project_access :: ProjectAccess.t()

  @typedoc "What `track_access/2` answers. See `Ravix.Accounts.TrackAccess`."
  @type track_access :: TrackAccess.t()

  @doc """
  All open tracks in the requested projects admitted by this viewer's memberships.

  `closed:` maps projects whose closed tracks are wanted too to how many:
  the most recently closed first, ranked after the visibility test, so
  another person's private track stays out and never takes a place. Still
  one query however many projects ask. Each row carries its creator's avatar
  and when its newest prompt was accepted (`last_prompt_at`).
  """
  @spec open_tracks(User.t(), [String.t()], closed: %{String.t() => pos_integer()}) ::
          [{Track.t(), Project.t()}]
  def open_tracks(%User{id: user_id}, project_ids, opts \\ []) do
    import Ecto.Query

    closed = Keyword.get(opts, :closed, %{})

    ranked =
      from(t in Track,
        as: :track,
        join: p in Project,
        as: :project,
        on: p.id == t.project_id,
        where: p.id in ^project_ids and is_nil(p.archived_at) and is_nil(p.deletion_requested_at),
        where: is_nil(t.closed_at) or t.project_id in ^Map.keys(closed)
      )
      |> visible(user_id)
      |> select([t], %{
        id: t.id,
        rank:
          over(row_number(),
            partition_by: [t.project_id, fragment("? IS NULL", t.closed_at)],
            order_by: [desc: t.closed_at, desc: t.id]
          )
      })

    within =
      Enum.reduce(closed, dynamic([t], is_nil(t.closed_at)), fn {id, limit}, acc ->
        dynamic([t, r], ^acc or (t.project_id == ^id and r.rank <= ^limit))
      end)

    # ownership: no door before this one; this query establishes project and
    # track membership. The prompt queue is read for the admitted rows only,
    # and only its newest timestamp, never a prompt's body.
    Repo.all(
      from(t in Track,
        as: :row,
        join: r in subquery(ranked),
        on: r.id == t.id,
        join: p in Project,
        on: p.id == t.project_id,
        left_join: u in User,
        on: u.id == t.created_by,
        left_lateral_join: q in subquery(last_prompt()),
        on: true,
        where: ^within,
        order_by: [asc: t.created_at, asc: t.id],
        select: {%{t | creator_avatar_url: u.avatar_url, last_prompt_at: q.created_at}, p}
      )
    )
  end

  # `sequence` is the order prompts were accepted in, and is indexed by track.
  defp last_prompt do
    import Ecto.Query

    from(q in Ravix.PromptQueue.Item,
      where: q.track_id == parent_as(:row).id,
      order_by: [desc: q.sequence],
      limit: 1,
      select: %{created_at: q.created_at}
    )
  end

  @doc """
  The ids of live projects this viewer may enter whole, as `project_access/2`
  would admit them one at a time: owned, or joined as a project member, or --
  with `Ravix.Config.workspace_access?/0` on -- in a workspace they are a live
  member of. A track share admits nothing here.
  """
  @spec project_ids(User.t()) :: [String.t()]
  # ownership: no door before this one; this query establishes project membership.
  def project_ids(%User{id: user_id}) do
    import Ecto.Query

    query =
      from(p in Project,
        as: :project,
        left_join: pm in Ravix.Projects.ProjectMember,
        as: :vis_pm,
        on: pm.project_id == p.id and pm.user_id == ^user_id,
        where: is_nil(p.archived_at) and is_nil(p.deletion_requested_at),
        distinct: true,
        select: p.id
      )

    if Ravix.Config.workspace_access?() do
      query
      |> workspace_joins(user_id)
      |> where(
        [project: p, vis_pm: pm, vis_wm: wm],
        p.user_id == ^user_id or not is_nil(pm.user_id) or not is_nil(wm.user_id)
      )
      |> Repo.all()
    else
      query
      |> where([project: p, vis_pm: pm], p.user_id == ^user_id or not is_nil(pm.user_id))
      |> Repo.all()
    end
  end

  @doc "Whether this person made the track: the stable id, or the login on rows from before it."
  def created_by?(%User{id: id, login: login}, %{created_by: creator} = track),
    do: if(is_nil(creator), do: track.created_by_login == login, else: creator == id)

  @doc """
  Narrow a query over tracks to the ones `user_id` may see: the one listing
  predicate, as `visible_track?/3` is the one row predicate. Every surface
  that lists tracks by viewer -- the rail, MCP, badges, search -- goes
  through this, so a private sibling's name or count cannot reach a list
  the creator did not share it into.

  The query binds the track as `:track` and its project as `:project`; this
  adds its own joins under `:vis_*` names. With `RAVIX_WORKSPACE_ACCESS`
  off it is exactly the legacy rule:

    * a legacy track seat (`track_members`, from an invitation or link);
    * a private track's creator, until project removal revoked them;
    * a project-visible track, to the project's owner and members.

  With it on, a project in a workspace also admits (a legacy project, with
  no workspace, reads exactly as above):

    * a project-visible track, to live members of that workspace;
    * a private track, to whoever holds a permission row on it *and* is
      still a live member of that workspace.

  and its private tracks' creators count only while they still reach the
  project, through the workspace or a legacy grant: leaving the workspace
  ends even the creator's access (ADR 0009). Owners and admins get no
  implicit read of a private track.
  """
  @spec visible(Ecto.Queryable.t(), String.t()) :: Ecto.Query.t()
  def visible(query, user_id) do
    import Ecto.Query

    query =
      query
      |> join(:left, [project: p], pm in Ravix.Projects.ProjectMember,
        as: :vis_pm,
        on: pm.project_id == p.id and pm.user_id == ^user_id
      )
      |> join(:left, [track: t], tm in Ravix.Tracks.TrackMember,
        as: :vis_tm,
        on: tm.track_id == t.id and tm.user_id == ^user_id
      )

    if Ravix.Config.workspace_access?() do
      query
      |> workspace_joins(user_id)
      |> join(:left, [track: t, vis_wm: wm], tp in Ravix.Tracks.TrackPermission,
        as: :vis_tp,
        on: tp.track_id == t.id and tp.user_id == ^user_id and tp.workspace_id == wm.workspace_id
      )
      |> where(^workspace_visibility(user_id))
    else
      where(query, ^legacy_visibility(user_id))
    end
  end

  defp legacy_visibility(user_id) do
    import Ecto.Query

    dynamic(
      [track: t, project: p, vis_pm: pm, vis_tm: tm],
      not is_nil(tm.user_id) or
        (t.visibility == :private and t.created_by == ^user_id and is_nil(t.creator_revoked_at)) or
        (t.visibility == :project and (p.user_id == ^user_id or not is_nil(pm.user_id)))
    )
  end

  defp workspace_visibility(user_id) do
    import Ecto.Query

    in_project = in_project(user_id)
    creator = still_creator(user_id, in_project)

    dynamic(
      [track: t, vis_tm: tm, vis_tp: tp],
      not is_nil(tm.user_id) or ^creator or
        (t.visibility == :private and not is_nil(tp.user_id)) or
        (t.visibility == :project and ^in_project)
    )
  end

  # Still in the project: through its workspace, or a legacy grant.
  defp in_project(user_id) do
    import Ecto.Query

    dynamic(
      [project: p, vis_pm: pm, vis_wm: wm],
      p.user_id == ^user_id or not is_nil(pm.user_id) or not is_nil(wm.user_id)
    )
  end

  # A private track's creator, while they are still in its project. A legacy
  # project, with no workspace, keeps its creators as before.
  defp still_creator(user_id, in_project) do
    import Ecto.Query

    dynamic(
      [track: t, project: p],
      t.visibility == :private and t.created_by == ^user_id and is_nil(t.creator_revoked_at) and
        (is_nil(p.workspace_id) or ^in_project)
    )
  end

  # The viewer's live membership of the project's live workspace, as `:vis_wm`.
  # Null for a legacy project, an archived workspace or a revoked membership.
  defp workspace_joins(query, user_id) do
    import Ecto.Query

    query
    |> join(:left, [project: p], w in Ravix.Workspaces.Workspace,
      as: :vis_w,
      on: w.id == p.workspace_id and is_nil(w.archived_at)
    )
    |> join(:left, [vis_w: w], wm in Ravix.Workspaces.Membership,
      as: :vis_wm,
      on: wm.workspace_id == w.id and wm.user_id == ^user_id and is_nil(wm.revoked_at)
    )
  end

  @doc "A thread is reached only through membership of its specified track."
  @spec thread_access(User.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found}
  def thread_access(user, track_id, thread_id \\ nil) do
    with {:ok, access} <- track_access(user, track_id),
         # ownership: Access.track_access above admitted this user to this exact track.
         %Ravix.Tracks.Thread{} = thread <- Ravix.Tracks.Store.thread(track_id, thread_id) do
      {:ok,
       %{
         track: access.track,
         project: access.project,
         role: access.role,
         level: access.level,
         thread: thread
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  `thread_access/3` for somebody who must hold at least `need` on the track
  (ADR 0010). Refused, rather than not found, for somebody who can see it:
  the track is not absent to them.
  """
  @spec thread_access(User.t(), String.t(), String.t() | nil, level()) ::
          {:ok, map()} | {:error, :not_found | {:forbidden, String.t()}}
  def thread_access(user, track_id, thread_id, need) when need in @levels do
    with {:ok, access} <- thread_access(user, track_id, thread_id),
         :ok <- require_level(access.level, need),
         do: {:ok, access}
  end

  @doc """
  A project the caller **owns**. Not found for anyone else's.

  The project's *controls* go through this and nothing else: its settings,
  its packages and secrets, the rebuild, and the delete. Somebody invited to
  the project is not a caller here (they are a caller at `project_access/2`)
  and gets the same answer as a stranger, because a machine you were let
  onto is still not a machine you get to re-provision.
  """
  @spec project_of(User.t(), String.t()) :: {:ok, Project.t()} | {:error, :not_found}
  def project_of(%User{id: user_id}, project_id) do
    case live_project(project_id) do
      %Project{user_id: ^user_id} = project -> {:ok, project}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  A project the caller may work in, and in what capacity.

  The wider door, and the one added when "invite somebody to the whole
  project" became a thing ravix can do. A project member reaches every
  track on it, the ones open now and the ones opened tomorrow, and may cut
  tracks of their own, because a project you were let into where you cannot
  start a line of work is only a bundle of track invitations with a nicer
  name.

  What it is *not* is `project_of/2`. The line between the two is the line
  the README draws: the work on the machine is shared, the machine is not.
  So the settings panel, the package list, the secrets, the rebuild and the
  delete all keep resolving through `project_of/2` and refuse a member
  exactly as they refuse a stranger.
  """
  @spec project_access(User.t(), String.t()) :: {:ok, project_access()} | {:error, :not_found}
  def project_access(%User{id: user_id}, project_id) do
    case live_project(project_id) do
      nil ->
        {:error, :not_found}

      %Project{user_id: ^user_id} = project ->
        {:ok, %ProjectAccess{project: project, role: :owner, level: :admin}}

      %Project{} = project ->
        # ownership: no door before this one -- the membership's role is part
        # of what this door decides, as `project_member?/2` is.
        direct = People.project_member_role(project.id, user_id)
        in_workspace? = is_nil(direct) and workspace_member?(project, user_id)

        case project_grant(false, direct, in_workspace?) do
          nil -> {:error, :not_found}
          {level, _source} -> {:ok, %ProjectAccess{project: project, role: :member, level: level}}
        end
    end
  end

  @typedoc """
  Where somebody's level on a project comes from (RAV-75): they own it, a
  direct grant (a project membership) names them, or the project's
  workspace admits them at its default.
  """
  @type source :: :owner | :direct | :workspace

  @typedoc """
  Where somebody's level on a track comes from: the owner (or a private
  track's creator), a grant on this track, the project's own grant, or the
  workspace's default.
  """
  @type track_source :: :owner | :direct | :project | :workspace

  # The precedence rule, one tier at a time (RAV-75, ADR 0010's addendum):
  # owner, then a direct grant, then the workspace. The first tier that
  # names somebody decides their level, whether it is higher or lower than
  # the tier below it: that is what lets an admin give a workspace member a
  # *different* role, Read included, and what makes removing that grant
  # fall back to the workspace's.
  defp project_grant(true, _direct, _in_workspace?), do: {:admin, :owner}
  defp project_grant(false, direct, _in_workspace?) when direct in @levels, do: {direct, :direct}
  defp project_grant(false, nil, true), do: {:write, :workspace}
  defp project_grant(false, nil, false), do: nil

  @doc """
  Everyone who reaches a project, at the level they reach it with and where
  that level comes from: `{user, level, source}`, owner first, then direct
  grants, then the workspace's members. For somebody who may enter the
  project (`project_access/2`); not found for anybody else.

  Decided by the same rule as `project_access/2`, so the list cannot show a
  level the door would not give.
  """
  @spec project_people(User.t(), String.t()) ::
          {:ok, [{User.t(), level(), source()}]} | {:error, :not_found}
  def project_people(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- project_access(user, project_id),
         do: {:ok, project_reach(project)}
  end

  defp project_reach(project) do
    # ownership: `Access.project_people/2` admitted the caller through
    # `Access.project_access/2`; these are who else that door admits.
    direct = grants_by_id(People.project_grants(project.id))
    workspace = workspace_members(project)
    in_workspace = MapSet.new(workspace, & &1.id)

    [Ravix.Accounts.Store.get_user(project.user_id)]
    |> people_in(Map.values(direct), workspace)
    |> Enum.flat_map(fn person ->
      owner? = person.id == project.user_id
      in_workspace? = MapSet.member?(in_workspace, person.id)
      reached(project_grant(owner?, role_of(direct, person), in_workspace?), person)
    end)
    |> sort_people()
  end

  @doc """
  `project_people/2` for one track: everyone who reaches it, as
  `{user, level, source}`, by the same rule `track_access/2` applies to one
  person at a time. For the Share dialog. Not found for anybody who cannot
  reach the track.
  """
  @spec track_people(User.t(), String.t()) ::
          {:ok, [{User.t(), level(), track_source()}]} | {:error, :not_found}
  def track_people(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- track_access(user, track_id),
         do: {:ok, track_reach(track, project)}
  end

  # The facts `track_access/2` decides from, read for everybody at once.
  defp track_reach(track, project) do
    # ownership: `Access.track_people/2` admitted the caller through
    # `Access.track_access/2`; these are the seats and grants it decides from.
    seats = grants_by_id(People.track_grants(track.id))
    # ownership: as above, the project's own grants.
    wide = grants_by_id(People.project_grants(project.id))
    workspace = workspace_members(project)
    in_workspace = MapSet.new(workspace, & &1.id)
    permitted = permitted_on(track, project, workspace)
    permitted_ids = MapSet.new(permitted, & &1.id)

    [Ravix.Accounts.Store.get_user(project.user_id), creator_of(track)]
    |> people_in(Map.values(seats) ++ Map.values(wide), workspace ++ permitted)
    |> Enum.flat_map(fn person ->
      facts = %{
        owner?: person.id == project.user_id,
        creator?: creator?(person, track),
        seat: role_of(seats, person),
        project_role: role_of(wide, person),
        in_workspace?: MapSet.member?(in_workspace, person.id),
        permitted?: MapSet.member?(permitted_ids, person.id)
      }

      if (is_nil(track.closed_at) or facts.owner?) and visible?(facts, track, project),
        do: reached(track_grant(facts, track), person),
        else: []
    end)
    |> sort_people()
  end

  defp grants_by_id(grants), do: Map.new(grants, fn {u, role} -> {u.id, {u, role}} end)

  defp role_of(grants, person) do
    case grants[person.id] do
      {_user, role} -> role
      nil -> nil
    end
  end

  defp people_in(named, grants, members) do
    (named ++ Enum.map(grants, &elem(&1, 0)) ++ members)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp reached(nil, _person), do: []
  defp reached({level, source}, person), do: [{person, level, source}]

  # Permission rows count only for live members of a live workspace.
  defp permitted_on(_track, _project, []), do: []

  defp permitted_on(track, project, _workspace) do
    # ownership: `Access.track_people/2` admitted the caller through
    # `Access.track_access/2`; these are the permission rows it decides from.
    Map.get(People.permitted_by_track([track.id], project.workspace_id), track.id, [])
  end

  defp creator_of(%Track{created_by: id}) when is_binary(id) do
    # ownership: `Access.track_people/2` admitted the caller through
    # `Access.track_access/2`; the creator is read for who they are.
    Ravix.Accounts.Store.get_user(id)
  end

  defp creator_of(_track), do: nil

  # Live members of the project's live workspace, while the switch lets
  # them count: the list `workspace_member?/2` answers about one at a time.
  defp workspace_members(%Project{workspace_id: workspace_id}) when is_binary(workspace_id) do
    # ownership: no door -- `Access.project_people/2` and `Access.track_people/2`
    # admitted their callers to this workspace's project first; these are the
    # members its workspace grant reaches.
    if Ravix.Config.workspace_access?() and Ravix.Workspaces.Store.live_workspace(workspace_id),
      do: Ravix.Workspaces.Store.live_members(workspace_id),
      else: []
  end

  defp workspace_members(%Project{}), do: []

  defp sort_people(people) do
    Enum.sort_by(people, fn {user, _level, source} ->
      {source_rank(source), String.downcase(user.login || "")}
    end)
  end

  defp source_rank(:owner), do: 0
  defp source_rank(:direct), do: 1
  defp source_rank(:project), do: 2
  defp source_rank(:workspace), do: 3

  @doc """
  `project_access/2` for somebody who must hold at least `need` across the
  project (ADR 0010): `:write` to cut a track, `:admin` to manage its people.
  """
  @spec project_access(User.t(), String.t(), level()) ::
          {:ok, project_access()} | {:error, :not_found | {:forbidden, String.t()}}
  def project_access(user, project_id, need) when need in @levels do
    with {:ok, access} <- project_access(user, project_id),
         :ok <- require_level(access.level, need, "project"),
         do: {:ok, access}
  end

  @doc "Whether `level` covers `need`: admin covers write, write covers read."
  @spec allows?(level(), level()) :: boolean()
  def allows?(level, need) when level in @levels and need in @levels,
    do: rank(level) >= rank(need)

  def allows?(_level, _need), do: false

  @doc "The refusal for somebody whose role on a track or project does not cover `need`."
  @spec require_level(level(), level(), String.t()) :: :ok | {:error, {:forbidden, String.t()}}
  def require_level(level, need, unit \\ "track") do
    if allows?(level, need),
      do: :ok,
      else: {:error, {:forbidden, "Your role on this #{unit} is #{label(level)}. #{needs(need)}"}}
  end

  defp label(level) when level in @levels, do: level |> Atom.to_string() |> String.capitalize()
  defp label(_level), do: "unknown"

  defp needs(:write), do: "Ask an admin for Write to do that."
  defp needs(:admin), do: "Only an admin can do that."
  defp needs(:read), do: "You cannot see this."

  defp rank(:read), do: 0
  defp rank(:write), do: 1
  defp rank(:admin), do: 2

  # Within one tier only; between tiers, the nearer grant decides.
  defp highest(levels), do: Enum.max_by(levels, &rank/1)

  @doc """
  Whether `user_id` is a live member of `project`'s live workspace, and the
  switch lets that count. False for a legacy project, which has none, and
  for everybody while `Ravix.Config.workspace_access?/0` is off.

  A workspace member reaches the project as a legacy project member does
  (`:member`, `:project`): its project-visible tracks and cutting their
  own. Not its controls: `project_of/2` stays the legacy owner's.
  """
  @spec workspace_member?(Project.t(), String.t()) :: boolean()
  def workspace_member?(%Project{workspace_id: workspace_id}, user_id)
      when is_binary(workspace_id) do
    Ravix.Config.workspace_access?() and
      match?({:ok, _}, workspace_access(%User{id: user_id}, workspace_id))
  end

  def workspace_member?(%Project{}, _user_id), do: false

  @doc """
  The projects a live workspace membership admits `user` to, and those
  workspaces themselves and their ids -- none while the switch is off. For
  a caller listing several projects (`Ravix.Projects.list/2`), which passes
  the ids back to `access_of/3` as `known: [workspaces: ...]` and reads each
  project's name against its workspace (RAV-128) without a read per row.
  """
  @spec workspace_reach(User.t()) :: %{
          projects: [Project.t()],
          workspaces: [Ravix.Workspaces.Workspace.t()],
          workspace_ids: [String.t()]
        }
  def workspace_reach(%User{id: user_id}) do
    if Ravix.Config.workspace_access?() do
      # ownership: no door before this one -- a live membership is the fourth
      # way in, and these reads are that fact.
      workspaces = Enum.map(Ravix.Workspaces.Store.workspaces_of(user_id), &elem(&1, 0))

      %{
        projects: Ravix.Workspaces.Store.member_projects(user_id),
        workspaces: workspaces,
        workspace_ids: Enum.map(workspaces, & &1.id)
      }
    else
      %{projects: [], workspaces: [], workspace_ids: []}
    end
  end

  @doc """
  Whether anybody besides the owner reaches `track` through its workspace:
  a permission row on a private track, another live member for a
  project-visible one. False for a legacy project and while the switch is
  off. Not an access decision -- it is whether the agent is told who is
  speaking (`Ravix.PromptQueue.Server`), for a sender already admitted.
  """
  @spec workspace_shared?(Track.t(), Project.t()) :: boolean()
  def workspace_shared?(%Track{} = track, %Project{workspace_id: workspace_id} = project)
      when is_binary(workspace_id) do
    Ravix.Config.workspace_access?() and
      if track.visibility == :private,
        # ownership: no door -- the sender was admitted by `track_access/2`;
        # this reads only whether the track has an audience.
        do: People.permitted_any?(track.id),
        else: Ravix.Workspaces.Store.others_in?(workspace_id, project.user_id)
  end

  def workspace_shared?(%Track{}, %Project{}), do: false

  @doc """
  Who reaches a project's tracks through its workspace, for the people
  lists and @mentions: its live members, and the live members holding a
  permission row on each of `track_ids`. Empty for a legacy project and
  while the switch is off, which is what keeps those lists as they are.
  Each person still reaches a given track only as `visible_track?/3` says:
  a member is on a project-visible track's list, a holder on its private one.
  """
  @spec workspace_audience(String.t(), [String.t()]) :: %{
          members: [User.t()],
          permitted: %{String.t() => [User.t()]}
        }
  def workspace_audience(project_id, track_ids) do
    with true <- Ravix.Config.workspace_access?(),
         %Project{workspace_id: workspace_id} when is_binary(workspace_id) <-
           live_project(project_id) do
      # ownership: no door -- callers were admitted to these tracks by
      # `track_access/2` or `open_tracks/2`; these are the facts it decides from.
      %{
        members: Ravix.Workspaces.Store.live_members(workspace_id),
        permitted: People.permitted_by_track(track_ids, workspace_id)
      }
    else
      _ -> %{members: [], permitted: %{}}
    end
  end

  @doc """
  A workspace the caller is an unrevoked member of, and their role in it.

  ADR 0009's fourth door. It answers about the workspace row alone, switch
  or no switch; what a membership admits to *beyond* that row is
  `workspace_member?/2`'s question, which the switch gates. Somebody else's
  workspace, a revoked membership, an archived workspace and an id that
  does not exist all answer not found.
  """
  @spec workspace_access(User.t(), String.t()) ::
          {:ok, %{workspace: Ravix.Workspaces.Workspace.t(), role: workspace_role()}}
          | {:error, :not_found}
  def workspace_access(%User{id: user_id}, workspace_id) do
    # ownership: no door before this one -- it is the door, as `member?/2` is.
    with %{} = workspace <- Ravix.Workspaces.Store.live_workspace(workspace_id),
         # ownership: no door before this one; this membership read is the door.
         %{role: role} <- Ravix.Workspaces.Store.membership(workspace.id, user_id) do
      {:ok, %{workspace: workspace, role: role}}
    else
      _ -> {:error, :not_found}
    end
  end

  @typedoc "A role in a workspace, as ADR 0009 names them."
  @type workspace_role :: :owner | :admin | :member

  @typedoc """
  What a workspace role may do. `:see_workspace_tracks` is the tracks
  whose visibility admits the workspace; no role reads a private track it
  was not given.
  """
  @type workspace_capability ::
          :manage_roles
          | :delete_workspace
          | :add_installations
          | :manage_members
          | :rename_workspace
          | :connect_repos
          | :manage_projects
          | :create_project
          | :create_track
          | :see_workspace_tracks

  @owner_only [:manage_roles, :delete_workspace, :add_installations]
  @admin [:manage_members, :rename_workspace, :connect_repos, :manage_projects, :create_project]
  @member [:create_track, :see_workspace_tracks]

  @doc """
  Whether a workspace role carries a capability (ADR 0009's roles).

  Owners transfer ownership, appoint admins and delete the workspace
  (`:manage_roles`, `:delete_workspace`), and add a GitHub installation
  they can see themselves (`:add_installations`, RAV-69). Admins also manage members,
  rename the workspace (`:rename_workspace`, RAV-72), repository connections and
  project settings and secrets, and admit
  repositories as projects. Members work on the tracks visibility admits
  them to and start tracks. Pure: it answers about a role, not a person;
  `workspace_grant/3` is the door that asks about a person.
  """
  @spec can?(workspace_role(), workspace_capability()) :: boolean()
  def can?(:owner, capability), do: capability in (@owner_only ++ @admin ++ @member)
  def can?(:admin, capability), do: capability in (@admin ++ @member)
  def can?(:member, capability), do: capability in @member
  def can?(_role, _capability), do: false

  @doc """
  The workspace door for something a workspace role *grants*.

  `workspace_access/2` plus `can?/2`, behind `Ravix.Config.workspace_access?/0`:
  while that switch is off a workspace grants nothing, so this answers not
  found for everybody, members included. With it on, a member whose role
  lacks the capability is refused rather than told the workspace is absent,
  because it is not absent to them.
  """
  @spec workspace_grant(User.t(), String.t(), workspace_capability()) ::
          {:ok, %{workspace: Ravix.Workspaces.Workspace.t(), role: workspace_role()}}
          | {:error, :not_found | {:forbidden, String.t()}}
  def workspace_grant(%User{} = user, workspace_id, capability) do
    with true <- Ravix.Config.workspace_access?() || {:error, :not_found},
         {:ok, %{role: role}} = access <- workspace_access(user, workspace_id),
         :ok <- require_capability(role, capability) do
      access
    end
  end

  @doc """
  Whether the caller may create a team workspace (ADR 0009, phase 4a).

  Anybody signed in may, and becomes its owner; there is no workspace to
  look up yet, so the only question is the switch. While
  `Ravix.Config.workspace_access?/0` is off this answers not found, as
  `workspace_grant/3` does.
  """
  @spec workspace_creation(User.t()) :: :ok | {:error, :not_found}
  def workspace_creation(%User{id: id}) when is_binary(id) do
    if Ravix.Config.workspace_access?(), do: :ok, else: {:error, :not_found}
  end

  @doc "The refusal for a workspace role without `capability`."
  @spec require_capability(workspace_role(), workspace_capability()) ::
          :ok | {:error, {:forbidden, String.t()}}
  def require_capability(role, capability) do
    if can?(role, capability),
      do: :ok,
      else: {:error, {:forbidden, "Your role in this workspace cannot do that."}}
  end

  @doc """
  A track the caller may reach, and in what capacity.

  Two ways in, and the order they are tried in is the order of how much they
  grant. Somebody named on *this track* gets this track: a second track of
  the same project lands here again and is refused again, which is what
  makes "an invitation is to a branch, not to the machine" true by
  construction rather than by everybody remembering. Somebody invited to the
  **project** gets all of them, which is the point of that invitation and is
  why it is a separate, deliberate act by the owner rather than something a
  track invite grows into.

  Both come back as `:member`. The distinction between them is about how
  they got here, not about what they may do once they are, and every caller
  of this door wants the second question.

  A project that has been archived is gone for its members too, and a closed
  track stops admitting anyone: neither has a surface left to share.
  """
  @spec track_access(User.t(), String.t()) :: {:ok, track_access()} | {:error, :not_found}
  def track_access(%User{id: user_id}, track_id) do
    with %Track{} = track <- get_track(track_id),
         %Project{} = project <- live_project(track.project_id) do
      facts = track_facts(user_id, track, project)
      grant = visible?(facts, track, project) && track_grant(facts, track)

      cond do
        not is_tuple(grant) ->
          {:error, :not_found}

        # The owner is admin of every track they can see but one: a private
        # track somebody else made, which its creator runs (#299). There the
        # owner has what their seat gives them, like anybody else on it.
        project.user_id == user_id ->
          {:ok, %TrackAccess{track: track, project: project, role: :owner, level: elem(grant, 0)}}

        track.closed_at != nil ->
          {:error, :not_found}

        # Visible and not the owner: every way `visible_track?/3` admits
        # somebody is a seat, a creator, a project or workspace member or a
        # permission row, and each of those works on the track as a member,
        # at the level of the nearest grant that reaches it (RAV-75).
        true ->
          {:ok,
           %TrackAccess{track: track, project: project, role: :member, level: elem(grant, 0)}}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  `track_access/2` for somebody who must hold at least `need` on the track
  (ADR 0010): `:write` to prompt, run a command or use the machine, `:admin`
  to manage its people. Somebody who can see the track and lacks the role is
  refused rather than told it is not there.
  """
  @spec track_access(User.t(), String.t(), level()) ::
          {:ok, track_access()} | {:error, :not_found | {:forbidden, String.t()}}
  def track_access(user, track_id, need) when need in @levels do
    with {:ok, access} <- track_access(user, track_id),
         :ok <- require_level(access.level, need),
         do: {:ok, access}
  end

  # What `track_access/2` decides from, for one person: the facts
  # `track_reach/2` reads for everybody at once. The owner of a
  # project-visible track needs none of the rows.
  defp track_facts(user_id, %Track{visibility: :project}, %Project{user_id: user_id}),
    do: %{
      owner?: true,
      creator?: false,
      seat: nil,
      project_role: nil,
      in_workspace?: false,
      permitted?: false
    }

  defp track_facts(user_id, track, project) do
    in_workspace? = workspace_member?(project, user_id)

    # ownership: no door before this one -- `track_access/2` is the door, and
    # the seat's and membership's roles are what it decides the level from.
    %{
      owner?: project.user_id == user_id,
      creator?: creator?(%User{id: user_id}, track),
      seat: People.member_role(track.id, user_id),
      project_role: People.project_member_role(project.id, user_id),
      in_workspace?: in_workspace?,
      permitted?:
        in_workspace? and track.visibility == :private and
          permitted?(track.id, user_id, project.workspace_id)
    }
  end

  # The one row predicate, over facts (see `visible/2` for the rule itself).
  # The switch is asked here, and a legacy project, with no workspace, reads
  # the legacy rule whatever it says.
  defp visible?(facts, track, project) do
    if Ravix.Config.workspace_access?() and is_binary(project.workspace_id),
      do: workspace_visible?(facts, track),
      else: legacy_visible?(facts, track)
  end

  defp legacy_visible?(facts, track) do
    (track.visibility == :private and facts.creator?) or not is_nil(facts.seat) or
      (track.visibility == :project and (facts.owner? or not is_nil(facts.project_role)))
  end

  defp workspace_visible?(facts, track) do
    in_project? = facts.in_workspace? or facts.owner? or not is_nil(facts.project_role)

    not is_nil(facts.seat) or
      case track.visibility do
        :project -> in_project?
        :private -> (facts.creator? and in_project?) or (facts.in_workspace? and facts.permitted?)
      end
  end

  # The level on a visible track and where it comes from, nearest grant
  # first (RAV-75): the owner, or a private track's creator, who runs it;
  # then a grant on this track, a seat or a permission row (the highest of
  # the two, should somebody hold both); then the project's own grant; then
  # the workspace's default. The first tier that names somebody decides,
  # lower or higher than the next. A project membership and the workspace
  # reach only the tracks the project can see, so neither says anything
  # about a private one: a track share never widens to the project, nor a
  # project role into a track kept private from it.
  defp track_grant(facts, %Track{visibility: :private}) do
    cond do
      facts.creator? -> {:admin, :owner}
      direct = direct_level(facts, true) -> {direct, :direct}
      true -> nil
    end
  end

  defp track_grant(facts, _track) do
    cond do
      facts.owner? -> {:admin, :owner}
      direct = direct_level(facts, false) -> {direct, :direct}
      facts.project_role -> {facts.project_role, :project}
      facts.in_workspace? -> {:write, :workspace}
      true -> nil
    end
  end

  # A seat, or a permission row on a private track; the higher, should
  # somebody hold both.
  defp direct_level(facts, private?) do
    case Enum.reject([facts.seat, if(private? and facts.permitted?, do: :write)], &is_nil/1) do
      [] -> nil
      levels -> highest(levels)
    end
  end

  @doc """
  Whether `user_id` may see a track: the one row predicate, the same rule
  `visible/2` applies to a list (see there for the rule itself). The switch
  is asked here and nowhere else, and a legacy project, with no workspace,
  reads the legacy rule whatever it says.
  """
  @spec visible_track?(String.t(), Track.t(), Project.t()) :: boolean()
  def visible_track?(user_id, %Track{} = track, %Project{} = project),
    do: visible?(track_facts(user_id, track, project), track, project)

  @doc "Stable creator identity; login is presentation only."
  def creator?(%User{id: id}, %{created_by: creator} = track),
    do: is_binary(creator) and creator == id and is_nil(Map.get(track, :creator_revoked_at))

  @doc "Sharing controls belong to the creator, or the owner of a project-visible track."
  def require_track_manager(_role, user, %{visibility: :private} = track, what) do
    if creator?(user, track),
      do: :ok,
      else: {:error, {:forbidden, "Only the track creator can #{what}."}}
  end

  def require_track_manager(role, _user, _track, what), do: require_owner(role, what)

  @doc """
  How `user_id` reaches `project`, or nil when they do not.

  The three ways in, widest first, and the order is what makes the answer
  stable: somebody who owns a project *and* somehow holds rows in it is
  still its owner, and somebody in the whole project who is also named on
  one track is still in the whole project. The narrowest answer has to be
  checked last or it wins over facts that grant more.

  The answer the rail draws its controls from, so it is finer than the
  `role` the doors above return: `:tracks` and `:project` are both
  `:member` at `track_access/2`, and both may not open the settings, but
  only one of them may cut a track. It used to be written out in
  `Ravix.Projects` and again in `Ravix.Tracks`, and the two had already
  drifted in how they asked the third question.

  `known` is for a caller with several projects to ask about. The rail has
  this person's memberships in hand from listing them; passing them here is
  what keeps "how do I reach this one" from costing two reads per project.
  Nothing about the project itself is trusted from it: `%Project{}` is
  whatever the caller was handed, and an archived one is the caller's to
  have excluded, exactly as with `Ravix.Projects.Store.get_project/1`.
  """
  @spec access_of(String.t(), Project.t(), known()) :: access() | nil
  def access_of(user_id, %Project{} = project, known \\ []) do
    cond do
      project.user_id == user_id -> :owner
      in_project?(project.id, user_id, known[:projects]) -> :project
      in_workspace?(project, user_id, known[:workspaces]) -> :project
      on_tracks?(project.id, user_id, known[:tracks]) -> :tracks
      true -> nil
    end
  end

  defp in_workspace?(project, user_id, nil), do: workspace_member?(project, user_id)

  defp in_workspace?(%Project{workspace_id: id}, _user_id, %MapSet{} = ids),
    do: is_binary(id) and Ravix.Config.workspace_access?() and MapSet.member?(ids, id)

  defp in_project?(project_id, user_id, nil), do: project_member?(project_id, user_id)
  defp in_project?(project_id, _user_id, %MapSet{} = ids), do: MapSet.member?(ids, project_id)

  # ownership: no door -- this *is* a door, as `member?/2` is: the third of
  # the three questions `access_of/3` exists to answer, not a read behind one.
  defp on_tracks?(project_id, user_id, nil), do: People.track_member_of?(project_id, user_id)
  defp on_tracks?(project_id, _user_id, %MapSet{} = ids), do: MapSet.member?(ids, project_id)

  defp on_tracks?(project_id, _user_id, tracks) when is_list(tracks),
    do: Enum.any?(tracks, &(&1.project_id == project_id))

  @doc "Owner-only operations on a track somebody else may also be in."
  @spec require_owner(role(), String.t()) :: :ok | {:error, {:forbidden, String.t()}}
  def require_owner(:owner, _what), do: :ok

  def require_owner(_role, what),
    do: {:error, {:forbidden, "Only the owner of this project can #{what}."}}

  @doc """
  The same, plus whoever cut the track.

  For renaming and closing, and it exists because project members can open
  tracks. Somebody who may make a directory on the machine and then may not
  tidy it up leaves the owner sweeping up after their guests, which is a
  worse outcome than the one owner-only was protecting against. It is still
  not "any member": being invited to help on a branch is not being handed
  the ability to end it for everybody else in it.

  Matched on the login rather than a user id because that is what the row
  holds: `created_by_login` is written for the ribbon, and the person who
  renames their GitHub account is a rarer event than the one this prevents.
  """
  @spec require_owner_or_cutter(role(), User.t(), Track.t(), String.t()) ::
          :ok | {:error, {:forbidden, String.t()}}
  def require_owner_or_cutter(role, user, %Track{visibility: :private} = track, what),
    do: require_track_manager(role, user, track, what)

  def require_owner_or_cutter(:owner, _user, _track, _what), do: :ok

  def require_owner_or_cutter(_role, %User{login: login}, %Track{created_by_login: cutter}, what) do
    if is_binary(cutter) and String.downcase(cutter) == String.downcase(login || "") do
      :ok
    else
      {:error,
       {:forbidden, "Only the owner of this project, or whoever opened this track, can #{what}."}}
    end
  end

  @doc """
  Whether `user_id` was named on `track_id`.

  # ownership: no door before this one -- it is the door. The question "was
  this person named on this track" has no earlier authorization to establish,
  because it *is* the authorization every other caller establishes.
  """
  @spec member?(String.t(), String.t()) :: boolean()
  defdelegate member?(track_id, user_id), to: People

  @doc """
  Whether `user_id` holds a permission row on `track_id` under `workspace_id`.

  # ownership: as `member?/2` -- no door before this one; it is the door,
  one of the facts `visible_track?/3` is made of.
  """
  @spec permitted?(String.t(), String.t(), String.t()) :: boolean()
  defdelegate permitted?(track_id, user_id, workspace_id), to: People

  @doc """
  Whether `user_id` was let into the whole of `project_id`.

  # ownership: as `member?/2` -- no door before this one; it is the door.
  """
  @spec project_member?(String.t(), String.t()) :: boolean()
  defdelegate project_member?(project_id, user_id), to: People

  # A project that exists and has not been archived. Every door starts here:
  # an archived project is gone for everybody, its owner included.
  #
  # ownership: no door before this one -- every door starts with this read.
  # `Ravix.Projects.Store.live_project/1` is that read, and lives there so this
  # module and `Ravix.People` cannot come to differ about what "archived" means.
  defp live_project(project_id), do: Projects.live_project(project_id)

  # ownership: a door again, with no door before it. Whether the track exists
  # at all is the first thing `track_access/2` has to know, before there is
  # anyone to check.
  defp get_track(track_id) when is_binary(track_id), do: Repo.get(Track, track_id)
  defp get_track(_), do: nil
end
