defmodule Ravix.People.Store do
  @moduledoc """
  The membership rows, with nobody's permission established.

  Every function here takes ids and touches the table. None of them asks who
  is calling, and none of them may be reached from a page. That is the whole
  of the contract, and it is a module boundary because it used to be a
  comment: these lived at the bottom of `Ravix.People` under a divider that
  said "treat every function below as unscoped", beside the scoped routes
  that share their names. `Ravix.People.drop_link/2` refused anyone but the
  owner; `Ravix.People.drop_link/1`, forty lines down the same file, refused
  nobody. Nothing could catch the wrong one being called, because to the
  compiler they were one module's two arities.

  Now the caller has to say `Store.` to get the unchecked one, and
  `Ravix.Credo.Architecture` fails the build if that caller is in
  `lib/ravix_web/` or is another context reaching in without a
  `# ownership:` comment naming the door it went through first.

  The legitimate callers are `Ravix.People` itself, which establishes access
  through `Ravix.Accounts.Access` before every one of these; `Access`, whose
  two membership questions *are* two of these reads; the sign-in that claims
  invitations before the person has any access to establish; and the track
  and project lists, which read seats and read-markers for people they have
  already been let in to see.
  """

  @typedoc "How this person comes to be in the list; see `Ravix.People.Person`."
  @type via :: Ravix.People.Person.via()

  @typedoc "A GitHub account, with no claim about access; see `Ravix.People.Profile`."
  @type profile :: Ravix.People.Profile.t()

  @typedoc "Somebody in a people list; see `Ravix.People.Person`."
  @type person :: Ravix.People.Person.t()

  @typedoc "An invitation waiting on a track or a project; see `Ravix.People.Invite`."
  @type invite :: Ravix.People.Invite.t()

  import Ecto.Query

  alias Ravix.Accounts.User
  alias Ravix.People.{Invite, Person, Profile}
  alias Ravix.Projects.{Project, ProjectInvite, ProjectLink, ProjectMember}
  alias Ravix.Projects.Store, as: Projects
  alias Ravix.Repo
  alias Ravix.Tracks.Store, as: Tracks
  alias Ravix.Tracks.{Track, TrackInvite, TrackLink, TrackMember, TrackRead}

  # ── who else is in a track ─────────────────────────────────────

  @doc "Seat `user_id` on a track. A second seat for the same person is not two seats."
  @spec add_member(String.t(), String.t(), String.t()) :: :ok
  def add_member(track_id, user_id, invited_by) do
    %TrackMember{}
    |> TrackMember.changeset(%{track_id: track_id, user_id: user_id, invited_by: invited_by})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:track_id, :user_id])

    :ok
  end

  @doc """
  Take `user_id` off a track, and with it every preview grant they held
  on it, so a browser tab they left open stops working with the row.

  The hub is told here rather than by the caller. This is the function that
  takes the access away, and a page holding the answer "yes, they may read
  this track" finds out it has changed by hearing `:people` on the project
  -- so the announcement belongs to the revocation and not to whichever of
  the routes above happened to ask for it. One caller forgetting would be a
  transcript still streaming to somebody who was removed from it.
  """
  @spec remove_member(String.t(), String.t()) :: :ok
  def remove_member(track_id, user_id) do
    # ownership: `Ravix.People.remove/3` admitted the caller through
    # `Access.track_access/2`. The seat being deleted below names this track
    # and this person, and their preview grants on it are part of what it gave.
    Ravix.Previews.Store.revoke(track_id, user_id)
    Ravix.Previews.Store.revoke_agent(track_id, user_id)

    Repo.delete_all(
      from(m in TrackMember, where: m.track_id == ^track_id and m.user_id == ^user_id)
    )

    # ownership: `Ravix.People.remove/3` admitted the caller through
    # `Access.track_access/2` on this track before taking the seat away, and
    # the seat named the track. Read only to learn which project's hub to tell.
    case Tracks.get_track(track_id) do
      %Track{project_id: project_id} -> Ravix.Hub.publish(project_id, :people, track_id: track_id)
      nil -> :ok
    end

    :ok
  end

  @doc "Whether `user_id` was named on this track. The owner is not: they own the project."
  @spec member?(String.t(), String.t()) :: boolean()
  def member?(track_id, user_id), do: seated?(TrackMember, :track_id, track_id, user_id)

  @doc "Everyone invited to a track, oldest invitation first. Excludes the owner."
  @spec members_of(String.t()) :: [User.t()]
  def members_of(track_id), do: seats_on(TrackMember, :track_id, track_id)

  @doc """
  `members_of/1` for several tracks at once, grouped by track id.

  A track nobody was named on is absent rather than empty; `people_by_track/3`
  supplies the default, since it is the one that knows every id it was asked
  about.
  """
  @spec members_by_track([String.t()]) :: %{String.t() => [User.t()]}
  def members_by_track(track_ids) do
    Repo.all(
      from(m in TrackMember,
        join: u in assoc(m, :user),
        where: m.track_id in ^track_ids,
        order_by: m.created_at,
        select: {m.track_id, u}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "The open tracks this person was invited to, across every project."
  @spec member_tracks(String.t()) :: [Track.t()]
  def member_tracks(user_id) do
    Repo.all(
      from(m in TrackMember,
        join: t in assoc(m, :track),
        where: m.user_id == ^user_id and is_nil(t.closed_at),
        order_by: t.created_at,
        select: t
      )
    )
  end

  @doc """
  Whether `user_id` was named on any open track of `project_id`.

  The third of the three ways into a project (see
  `Ravix.Accounts.Access.access_of/3`), asked as one `EXISTS` rather than
  by listing the person's tracks across every project and looking for this
  one in the answer. A closed track does not count, for the reason it does
  not count in `member_tracks/1`: there is no surface left on it to share.
  """
  @spec track_member_of?(String.t(), String.t()) :: boolean()
  def track_member_of?(project_id, user_id) do
    Repo.exists?(
      from(m in TrackMember,
        join: t in assoc(m, :track),
        where: m.user_id == ^user_id and t.project_id == ^project_id and is_nil(t.closed_at)
      )
    )
  end

  # ── invitations to somebody who is not here yet ────────────────

  @doc """
  Invite a GitHub account that has not signed in here to a track. Inviting
  the same account again refreshes the login and avatar it is shown with.
  """
  @spec add_invite(%{
          track_id: String.t(),
          github_id: String.t(),
          login: String.t(),
          avatar_url: String.t() | nil,
          invited_by: String.t()
        }) :: :ok
  def add_invite(attrs) do
    %TrackInvite{}
    |> TrackInvite.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, [:login, :avatar_url]},
      conflict_target: [:track_id, :github_id]
    )

    :ok
  end

  @doc "The invitations waiting on a track, oldest first."
  @spec invites_of(String.t()) :: [invite()]
  def invites_of(track_id), do: invites_on(TrackInvite, :track_id, track_id)

  @doc "`invites_of/1` for several tracks at once, grouped by track id. Absent when a track has none."
  @spec invites_by_track([String.t()]) :: %{String.t() => [invite()]}
  def invites_by_track(track_ids) do
    Repo.all(
      from(i in TrackInvite,
        where: i.track_id in ^track_ids,
        order_by: i.created_at,
        select:
          {i.track_id, %Invite{github_id: i.github_id, login: i.login, avatar_url: i.avatar_url}}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "Withdraw a track invitation by the login it was sent to. True when one was there to withdraw."
  @spec remove_invite_by_login(String.t(), String.t()) :: boolean()
  def remove_invite_by_login(track_id, login),
    do: withdraw_invite(TrackInvite, :track_id, track_id, login)

  @doc """
  Turn every invitation waiting for this person into a membership.

  Run once, on the sign-in that creates or refreshes their account.
  Matching is on the GitHub id the profile just came back with, so an
  invitation sent to a login they have since changed still finds them, and
  one sent to a login somebody *else* now holds does not.

  Returns what they just joined, so the sign-in can say so.

  Projects are claimed **first**, and a track invitation on a project they
  have just joined outright is then dropped rather than honoured. It grants
  nothing they do not already have, and writing it would be writing the
  narrower row that `add_project_member/3` exists to delete.
  """
  @spec claim_invites(String.t(), String.t()) :: %{tracks: [Track.t()], projects: [Project.t()]}
  def claim_invites(user_id, github_id) do
    {:ok, joined} =
      Repo.transaction(fn ->
        projects = claim_project_invites(user_id, github_id)
        tracks = claim_track_invites(user_id, github_id)
        %{tracks: tracks, projects: projects}
      end)

    joined
  end

  defp claim_project_invites(user_id, github_id) do
    pending =
      Repo.all(from(i in ProjectInvite, where: i.github_id == ^github_id, select: i.project_id))

    projects =
      for project_id <- pending,
          # ownership: no door yet -- this runs during sign-in for a person
          # whose invitation rows are the only claim they have. The project
          # is read to check it is still there, not to decide who may see it.
          %Project{} = project <- [Projects.live_project(project_id)],
          # An archived project is not somewhere to arrive, and neither is
          # your own: ownership is the stronger claim and is a column, not a
          # row here.
          project.user_id != user_id do
        add_project_member(project.id, user_id, "invite")
        project
      end

    Repo.delete_all(from(i in ProjectInvite, where: i.github_id == ^github_id))
    projects
  end

  defp claim_track_invites(user_id, github_id) do
    pending =
      Repo.all(from(i in TrackInvite, where: i.github_id == ^github_id, select: i.track_id))

    tracks =
      for track_id <- pending,
          # A track closed while the invitation sat unclaimed is not
          # somewhere to arrive. Drop the invitation rather than granting a
          # dead seat.
          # ownership: no door yet -- this is sign-in, and the invitation row
          # naming this track is the only claim the person has.
          %Track{closed_at: nil} = track <- [Tracks.get_track(track_id)],
          not project_member?(track.project_id, user_id) do
        add_member(track.id, user_id, "invite")
        track
      end

    Repo.delete_all(from(i in TrackInvite, where: i.github_id == ^github_id))
    tracks
  end

  # ── the link ───────────────────────────────────────────────────

  @doc "Put a track's one link, replacing whatever was there. `ttl_ms` from now."
  @spec put_link(String.t(), String.t(), String.t(), integer()) :: :ok
  def put_link(track_id, token_hash, created_by, ttl_ms),
    do: put_link_row(TrackLink, :track_id, track_id, token_hash, created_by, ttl_ms)

  @doc "When a track's link was made and when it lapses, or nil. Never the hash."
  @spec link_of(String.t()) :: %{created_at: DateTime.t(), expires_at: DateTime.t()} | nil
  def link_of(track_id), do: link_row(TrackLink, :track_id, track_id)

  @doc "Delete a track's link. Nobody who came in on it is touched."
  @spec drop_link(String.t()) :: :ok
  def drop_link(track_id), do: drop_link_row(TrackLink, :track_id, track_id)

  @doc "The track a link opens, or nil if it is unknown, revoked, expired, or the track closed."
  @spec track_for_link(String.t()) :: Track.t() | nil
  def track_for_link(token_hash) do
    with %TrackLink{} = link <- Repo.get_by(TrackLink, token_hash: token_hash),
         true <- live?(link.expires_at),
         # ownership: no door but the link: holding it is the authorization,
         # and the row it matched names this track.
         %Track{closed_at: nil} = track <- Tracks.get_track(link.track_id) do
      track
    else
      _ -> nil
    end
  end

  # ── who else is in a project ───────────────────────────────────

  @doc """
  Somebody into the whole project, replacing whatever narrower rows they had.

  The subsumption is the point, and it is here rather than in the route so
  that the three ways in (invited by name, arrived on a link, claimed on
  sign-in) cannot disagree about it. **One person holds one grade of access
  to a project.** Two rows granting the same person the same track by
  different routes is a state nothing on screen can render honestly: the
  people list would have to show them twice or pick one, and removing them
  from the project would leave behind access that neither list explained.

  So this is a promotion, not an addition, and the corollary is worth
  saying plainly because it is the surprising half: **taking somebody off a
  project takes away every track on it**, including one they were named on
  separately before they were promoted. The alternative, a hidden narrower
  row that survives, is worse, because it is invisible at exactly the
  moment somebody is trying to revoke access.
  """
  @spec add_project_member(String.t(), String.t(), String.t()) :: :ok
  def add_project_member(project_id, user_id, invited_by) do
    %ProjectMember{}
    |> ProjectMember.changeset(%{
      project_id: project_id,
      user_id: user_id,
      invited_by: invited_by
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:project_id, :user_id])

    Repo.delete_all(
      from(m in TrackMember,
        where: m.user_id == ^user_id and m.track_id in subquery(track_ids_of(project_id))
      )
    )

    :ok
  end

  @doc """
  Take `user_id` off a project: the row, and every preview grant on every
  open track of it.

  As with `remove_member/2`, the hub is told from here: this is where the
  access goes, so this is what announces it.
  """
  @spec remove_project_member(String.t(), String.t()) :: :ok
  def remove_project_member(project_id, user_id) do
    # ownership: `Ravix.People.remove_project/3` admitted the caller through
    # `Access.project_access/2`. Taking somebody off a project takes away every
    # track on it, so the open ones have to be named to revoke their previews;
    # `open_tracks/1` is the projects context's own read of that list.
    tracks = Projects.open_tracks(project_id)

    # ownership: the same `Access.project_access/2` door. The seat being
    # deleted below is what let this person onto every one of those tracks,
    # so their grants on each go with it.
    Enum.each(tracks, &Ravix.Previews.Store.revoke(&1.id, user_id))
    Enum.each(tracks, &Ravix.Previews.Store.revoke_agent(&1.id, user_id))

    Repo.delete_all(
      from(m in ProjectMember, where: m.project_id == ^project_id and m.user_id == ^user_id)
    )

    Ravix.Hub.publish(project_id, :people)
    :ok
  end

  @doc "Whether `user_id` was let into the whole project. The owner is not: ownership is a column."
  @spec project_member?(String.t(), String.t()) :: boolean()
  def project_member?(project_id, user_id),
    do: seated?(ProjectMember, :project_id, project_id, user_id)

  @doc "Everyone invited to the whole project, oldest first. Excludes the owner."
  @spec project_members_of(String.t()) :: [User.t()]
  def project_members_of(project_id), do: seats_on(ProjectMember, :project_id, project_id)

  @doc "The live projects this person was invited into whole. Never the ones they own."
  @spec member_projects(String.t()) :: [Project.t()]
  def member_projects(user_id) do
    Repo.all(
      from(m in ProjectMember,
        join: p in assoc(m, :project),
        where: m.user_id == ^user_id and is_nil(p.archived_at),
        order_by: p.created_at,
        select: p
      )
    )
  end

  @doc """
  The same promotion, for somebody who has not arrived yet.

  A pending track invitation on this project is dropped with it, for the
  reason the memberships are: it would grant nothing on the sign-in that
  honoured them both, and until then it sits in the track's people list as
  a row whose remove control cancels an invitation that was already
  superseded.
  """
  @spec add_project_invite(%{
          project_id: String.t(),
          github_id: String.t(),
          login: String.t(),
          avatar_url: String.t() | nil,
          invited_by: String.t()
        }) :: :ok
  def add_project_invite(%{project_id: project_id, github_id: github_id} = attrs) do
    %ProjectInvite{}
    |> ProjectInvite.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, [:login, :avatar_url]},
      conflict_target: [:project_id, :github_id]
    )

    Repo.delete_all(
      from(i in TrackInvite,
        where: i.github_id == ^github_id and i.track_id in subquery(track_ids_of(project_id))
      )
    )

    :ok
  end

  @doc "Whether an invitation to the whole project is already out for this GitHub account."
  @spec has_project_invite?(String.t(), String.t()) :: boolean()
  def has_project_invite?(project_id, github_id) do
    Repo.exists?(
      from(i in ProjectInvite, where: i.project_id == ^project_id and i.github_id == ^github_id)
    )
  end

  @doc "The invitations waiting on a project, oldest first."
  @spec project_invites_of(String.t()) :: [invite()]
  def project_invites_of(project_id), do: invites_on(ProjectInvite, :project_id, project_id)

  @doc "Withdraw a project invitation by the login it was sent to. True when one was there to withdraw."
  @spec remove_project_invite_by_login(String.t(), String.t()) :: boolean()
  def remove_project_invite_by_login(project_id, login),
    do: withdraw_invite(ProjectInvite, :project_id, project_id, login)

  @doc "Put a project's one link, replacing whatever was there. `ttl_ms` from now."
  @spec put_project_link(String.t(), String.t(), String.t(), integer()) :: :ok
  def put_project_link(project_id, token_hash, created_by, ttl_ms),
    do: put_link_row(ProjectLink, :project_id, project_id, token_hash, created_by, ttl_ms)

  @doc "When a project's link was made and when it lapses, or nil. Never the hash."
  @spec project_link_of(String.t()) :: %{created_at: DateTime.t(), expires_at: DateTime.t()} | nil
  def project_link_of(project_id), do: link_row(ProjectLink, :project_id, project_id)

  @doc "Delete a project's link. Nobody who came in on it is touched."
  @spec drop_project_link(String.t()) :: :ok
  def drop_project_link(project_id), do: drop_link_row(ProjectLink, :project_id, project_id)

  @doc "The project a link opens, or nil if it is unknown, revoked, expired or archived."
  @spec project_for_link(String.t()) :: Project.t() | nil
  def project_for_link(token_hash) do
    with %ProjectLink{} = link <- Repo.get_by(ProjectLink, token_hash: token_hash),
         true <- live?(link.expires_at),
         # ownership: no door but the link: holding it is the authorization,
         # and the row it matched names this project.
         %Project{} = project <- Projects.live_project(link.project_id) do
      project
    else
      _ -> nil
    end
  end

  # ── the same row, on either side of the line ─────────────────────────
  #
  # A track and a project are shared by the same three tables one level
  # apart, and seven of these reads were the same query written twice. They
  # are one query each now, with the schema and its key passed in.
  #
  # What is *not* here is as deliberate: `add_member/3`, `remove_member/2`,
  # `add_invite/1` and `track_for_link/1` still have their project twins
  # written out, because those four genuinely differ -- the wider grant
  # deletes the narrower rows, removing somebody from a project revokes
  # previews on every track under it, and a link is dead when its track
  # closes or its project is archived, which are different questions. Before
  # this, all eleven pairs looked alike and a reader had no way to tell the
  # seven that were the same from the four that were not.
  #
  # The public names stay one per unit of sharing. Passing the unit as an
  # argument would make `member?(wrong_scope, id, user)` a thing that
  # compiles, in the module where that answer decides who gets a shell.

  defp seated?(schema, key, id, user_id) do
    Repo.exists?(from(m in schema, where: field(m, ^key) == ^id and m.user_id == ^user_id))
  end

  defp seats_on(schema, key, id) do
    Repo.all(
      from(m in schema,
        join: u in assoc(m, :user),
        where: field(m, ^key) == ^id,
        order_by: m.created_at,
        select: u
      )
    )
  end

  defp invites_on(schema, key, id) do
    Repo.all(
      from(i in schema,
        where: field(i, ^key) == ^id,
        order_by: i.created_at,
        select: %Invite{github_id: i.github_id, login: i.login, avatar_url: i.avatar_url}
      )
    )
  end

  # True when there was one to withdraw, which is how the routes tell an
  # invitation that was cancelled from a name nobody had invited.
  defp withdraw_invite(schema, key, id, login) do
    lowered = String.downcase(login)

    {n, _} =
      Repo.delete_all(
        from(i in schema,
          where: field(i, ^key) == ^id and fragment("LOWER(?)", i.login) == ^lowered
        )
      )

    n > 0
  end

  # One row per subject, by primary key, which is what makes minting a new
  # link *the* revoke rather than a second thing to remember.
  defp put_link_row(schema, key, id, token_hash, created_by, ttl_ms) do
    now = DateTime.utc_now()

    schema
    |> struct()
    |> schema.changeset(%{
      key => id,
      :token_hash => token_hash,
      :created_by => created_by,
      :created_at => now,
      :expires_at => DateTime.add(now, ttl_ms, :millisecond)
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:token_hash, :created_by, :created_at, :expires_at]},
      conflict_target: key
    )

    :ok
  end

  defp link_row(schema, key, id) do
    Repo.one(
      from(l in schema,
        where: field(l, ^key) == ^id,
        select: %{created_at: l.created_at, expires_at: l.expires_at}
      )
    )
  end

  defp drop_link_row(schema, key, id) do
    Repo.delete_all(from(l in schema, where: field(l, ^key) == ^id))
    :ok
  end

  defp live?(expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp track_ids_of(project_id),
    do: from(t in Track, where: t.project_id == ^project_id, select: t.id)

  # ── what you have not read ─────────────────────────────────────

  @doc "Record that `user_id` looked at a track, at `at` (now by default)."
  @spec mark_read(String.t(), String.t(), DateTime.t()) :: :ok
  def mark_read(track_id, user_id, at \\ DateTime.utc_now()) do
    %TrackRead{}
    |> TrackRead.changeset(%{track_id: track_id, user_id: user_id, seen_at: at})
    |> Repo.insert!(on_conflict: {:replace, [:seen_at]}, conflict_target: [:track_id, :user_id])

    :ok
  end

  @doc "When this person last looked at each of a project's tracks, by track id."
  @spec reads_of(String.t(), String.t()) :: %{String.t() => DateTime.t()}
  def reads_of(user_id, project_id) do
    Repo.all(
      from(r in TrackRead,
        join: t in assoc(r, :track),
        where: r.user_id == ^user_id and t.project_id == ^project_id,
        select: {r.track_id, r.seen_at}
      )
    )
    |> Map.new()
  end

  @doc "When this person last looked at a track, or nil if never."
  @spec last_read_of(String.t(), String.t()) :: DateTime.t() | nil
  def last_read_of(track_id, user_id) do
    Repo.one(
      from(r in TrackRead,
        where: r.track_id == ^track_id and r.user_id == ^user_id,
        select: r.seen_at
      )
    )
  end

  # ── the link, as the page that follows one reads it ──────────────────

  @doc """
  Whoever minted the link now under `hash`, by login. Nil if nobody did.

  The row is re-read by hash as well as by id: a link that was replaced
  between a caller's lookup and this one belongs to whoever minted the
  *current* link, and naming the previous sender would be a small lie on a
  page whose whole job is saying who is asking.
  """
  @spec minted_by(module(), atom(), String.t(), String.t()) :: String.t() | nil
  def minted_by(schema, key, id, hash) do
    # ownership: no door -- a link is read before anybody is signed in, and
    # the hash is the authorization, matched against this row right here. The
    # user read turns the stored `created_by` into the login a page shows, and
    # nothing else is decided by it.
    with %{created_by: user_id} <- Repo.get_by(schema, [{key, id}, {:token_hash, hash}]),
         %User{login: login} <- Ravix.Accounts.Store.get_user(user_id) do
      login
    else
      _ -> nil
    end
  end

  @doc """
  The project a link's track sits on, if it is still there.

  Deliberately the same read `Ravix.Accounts.Access` makes, rather than a
  second opinion about what "archived" means. A link to a track on an
  archived project opens nothing.
  """
  # ownership: no door but the link -- another context's rows, reached because
  # a link that has already matched a track row names the project it is on.
  @spec live_project(String.t()) :: Ravix.Projects.Project.t() | nil
  defdelegate live_project(project_id), to: Projects

  # ── the people lists ─────────────────────────────────────────────────
  #
  # Assembly rather than access: ids in, a list of people out. They said
  # "Unscoped:" three times over while they lived in `Ravix.People`, which is
  # the sentence this module exists so that nobody has to write.

  @doc """
  Everyone on a track, owner first.

  The owner is not a row in `track_members`: they own the project, which is
  a stronger claim that survives every membership being deleted, so they
  are prepended here rather than written into the table. A synthetic row
  would have to be kept in step with the project's `user_id` forever, and
  the day it was not, the owner would lose their own track.

  Project members are in this list too, because the question it answers is
  "who can see this" and they can. They carry `via: :project` so the dialog
  can say *why* (a name you do not remember inviting to this branch is
  alarming until the row tells you it came in one level up) and so the
  remove control beside them can be the one that actually works.

  Somebody who is both is shown once, as a project member: that is the row
  that is granting the access, and it is the one whose removal would not be
  enough on its own.

  """
  @spec people_of(String.t(), String.t(), String.t()) :: [person()]
  def people_of(track_id, owner_id, project_id) do
    wide = project_members_of(project_id)

    assemble(
      shared_people(owner_id, wide),
      MapSet.new(wide, & &1.id),
      members_of(track_id),
      invites_of(track_id)
    )
  end

  @doc """
  `people_of/3` for a whole project's tracks at once, keyed by track id.

  The sidebar asks this of every track it lists, and asked one at a time it
  is four queries each: the same project members and the same owner, read
  again per row. Twenty tracks cost eighty-three queries and eighty of them
  had the answer already. Here the two project-wide lists are read once and
  the two per-track ones are read for every named track together, so the
  count stops depending on how many tracks a project has.

  Every id given is a key in the answer, including the tracks with nobody
  on them beyond the project's own people.

  """
  @spec people_by_track([String.t()], String.t(), String.t()) :: %{String.t() => [person()]}
  def people_by_track([], _owner_id, _project_id), do: %{}

  def people_by_track(track_ids, owner_id, project_id) do
    wide = project_members_of(project_id)
    shared = shared_people(owner_id, wide)
    seen = MapSet.new(wide, & &1.id)
    members = members_by_track(track_ids)
    invites = invites_by_track(track_ids)

    Map.new(track_ids, fn track_id ->
      {track_id,
       assemble(
         shared,
         seen,
         Map.get(members, track_id, []),
         Map.get(invites, track_id, [])
       )}
    end)
  end

  # The half of the list that is the same for every track on a project.
  defp shared_people(owner_id, wide) do
    owner_entry(owner_id) ++ Enum.map(wide, &Person.new(&1, :project))
  end

  # Pending last, because they cannot read anything yet and the list is
  # mostly read to answer "who can see this".
  defp assemble(shared, seen, members, invites) do
    narrow = Enum.reject(members, &MapSet.member?(seen, &1.id))

    shared ++
      Enum.map(narrow, &Person.new(&1, :track)) ++
      Enum.map(invites, &pending_person/1)
  end

  @doc """
  Everyone on a project, owner first: the same list one level up.

  Deliberately *not* a union with the track memberships underneath it. This
  list answers "who is in the project", and somebody named on one branch of
  it is not; showing them here would make the owner's own decision
  unreadable back to them, and would put a remove control beside a row
  that this dialog cannot remove.

  """
  @spec project_people_of(String.t(), String.t()) :: [person()]
  def project_people_of(project_id, owner_id) do
    members =
      project_id
      |> project_members_of()
      |> Enum.map(&Person.new(&1, :project))

    pending = project_id |> project_invites_of() |> Enum.map(&pending_person/1)
    owner_entry(owner_id) ++ members ++ pending
  end

  @doc "A `Ravix.People.Profile` for a user row: login, name, avatar, nothing else."
  @spec present_person(User.t()) :: profile()
  defdelegate present_person(user), to: Profile, as: :from_user

  defp pending_person(%Invite{login: login, avatar_url: avatar_url}),
    do: Person.pending(login, avatar_url)

  defp owner_entry(owner_id) do
    # ownership: turning the project's `user_id` column into a name for the
    # list, whose callers in `Ravix.People` went through `Access.track_access/2`
    # or `Access.project_access/2`. Ownership is that column, never a row here.
    case Ravix.Accounts.Store.get_user(owner_id) do
      %User{} = owner -> [Person.new(owner, :owner)]
      nil -> []
    end
  end
end
