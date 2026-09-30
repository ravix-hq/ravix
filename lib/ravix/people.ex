defmodule Ravix.People do
  @moduledoc """
  Working on something with somebody else.

  There are **two units of sharing**, and offering both is the design rather
  than a convenience. A track is one branch in one directory; a project is
  the machine every track sits on. Inviting somebody to a branch is a thing
  people do every day, and for a long time it was the only thing ravix
  offered, on the argument that inviting somebody to your *machine* is not
  an everyday act, which is true. What that argument missed is that working
  with the same person across a week of branches, re-inviting them to each
  one, is not an everyday act either. So:

    **A track member** gets exactly the track they were named on: its
    transcript, files, diff, terminal, and the ability to prompt it. They
    do not see the project's other tracks and cannot open one.

    **A project member** gets project-visible tracks, including future ones,
    and may cut tracks of their own. Private tracks require creator or
    track membership, even for the project owner. A
    project you were let into where you cannot start a line of work is only
    a bundle of track invitations under a grander name.

  Neither of them gets the project's **controls**: settings, packages,
  secrets, rebuild, delete. That line is the one thing both memberships
  have in common and it is drawn in `Ravix.Accounts.Access`: `project_of`
  for the machine, `project_access` for the work on it, `track_access` for
  one piece of the work.

  Project membership replaces narrower seats on project-visible tracks.
  Promotion preserves private track seats. Removal from the project revokes
  every track seat, creator access, outstanding prompt and invitation issued
  by that person in the project.

  ## What sharing actually costs

  It is worth being exact, because the invite dialogs say it and this is
  where the sentence is true or not.

  A legacy shared track is a shell on a machine that also holds other shared tracks. The
  worktrees are separate directories, and the agent is told three times
  over to stay in its own, but that is a rule the agent follows, not a
  boundary the kernel enforces. Somebody who can prompt a track can ask the
  agent to read a sibling directory, and it may do it. They can also ask it
  to print the environment, which on a project with environment secrets
  means those secrets.

  Which is the honest reason project-level sharing is not the leap it looks
  like on legacy machines: a shared-track invitation already costs most of what a project
  invitation costs, because they run on one box. Private tracks require their
  own dedicated machine. What the wider invitation adds is the
  ability to read the other transcripts and to open tracks: real, and worth
  a separate act by the owner, but not a different order of trust.

  What neither can do is reach the project's controls. The one worth
  knowing is the credential: the clone token lives in the vault and never
  lands on the machine, so no member can print it. The machine does not
  have it to print.

  ## Shape of this module

  Every function a page may call takes the signed-in
  `%Ravix.Accounts.User{}` and goes through one of the doors in
  `Ravix.Accounts.Access` before touching a row, and that is now something
  the compiler can show rather than something a reader has to check: the
  rows themselves live in `Ravix.People.Store`, which takes ids and asks
  nobody's permission.

  The two invite-link functions take no user, because an invitation is how
  somebody arrives *before* they have any access to establish.
  `link_target/1` says what a link opens for a browser holding one, which
  is deliberately readable by anyone who has the token and nothing else;
  `claim_link/2` takes a user *id* rather than a struct, because the
  sign-in callback has only just created the row. Both are documented
  individually below, and `Ravix.ArchitectureTest` keeps that list and this
  paragraph agreeing.

  One more takes no user and reads no row: `workspace_sharing?/1` says, of
  a project already in hand, whether its tracks are shared through its
  workspace's Share dialog or through the invitations and links above.

  They shared this module until they did not. `drop_link/2` refused anyone
  but the owner and `drop_link/1` refused nobody, forty lines apart under a
  divider asking the reader to remember which half they were in.
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.People.{InviteLink, LinkTarget, Person, Profile, Sharing, Store}
  alias Ravix.Projects.{Machine, Project, ProjectLink}
  alias Ravix.Tracks.{Track, TrackLink}

  @typedoc """
  Somebody in a people list, as a page reads it.

  `Ravix.People.Person` is a sibling of the store rather than inside it,
  which is what lets a page name the shape at all: `Ravix.Credo.Architecture`
  refuses a store from `lib/ravix_web/`, and a typespec is a mention.
  """
  @type person :: Person.t()

  @typedoc "How this person comes to be in the list; see `Ravix.People.Store.via/0`."
  @type via :: Store.via()

  @typedoc "A GitHub account the invite box suggests; see `Ravix.People.Profile`."
  @type profile :: Profile.t()

  @typedoc "A track's or project's one link; see `Ravix.People.InviteLink`."
  @type invite_link :: InviteLink.t()

  @type reason ::
          :not_found
          | {:forbidden, String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unconfigured, :github}
          | Ravix.GitHub.Error.t()

  # How long a link lasts.
  #
  # A week for a track, because the thing it is for is "have a look at this
  # with me", not "here is standing access". A link that never expires is a
  # credential somebody pasted into a chat two years ago and forgot, and
  # this one grants a shell on a machine.
  #
  # Two days for a project, and the shorter number is the whole of the
  # argument for having two. A project link is the widest thing ravix hands
  # out, every branch on the box and the ability to cut more, so it is the
  # one that should least survive being forgotten about. Nobody is worse
  # off: minting another is one button, and the people who came in on the
  # old one stay.
  @link_ttl_ms 7 * 24 * 60 * 60 * 1000
  @project_link_ttl_ms 2 * 24 * 60 * 60 * 1000

  # ── the invite box ───────────────────────────────────────────────────

  @doc """
  The invite box's autocomplete.

  This searches **everyone who has ever signed in to this deployment**, and
  that is a deliberate, accepted trade rather than an oversight: it means
  the box will confirm whether a given GitHub login has an account here.
  The alternative, only suggesting people you have already shared with,
  makes the box useless for the first invitation anybody sends, which is
  the one that matters.

  Two things keep it from being worse than that. It needs a session, so it
  is not an open directory of the userbase; and it returns only what GitHub
  already publishes about a person: login, display name, avatar. Never an
  email, and never anything about what they have here.
  """
  @spec search(User.t(), String.t() | nil) :: [profile()]
  def search(%User{} = user, q) do
    q = q |> to_string() |> String.trim()

    # One character is a fine query for a login; zero is a request for the
    # whole userbase, which is the one thing this should not hand over.
    if q == "" do
      []
    else
      # ownership: no door -- the person in hand is the caller, whose session
      # is the whole of what this needs, and their own id is passed only to
      # leave them out of a list about everybody else.
      q
      |> String.slice(0, 60)
      |> Ravix.Accounts.Store.search_users(user.id)
      |> Enum.map(&Store.present_person/1)
    end
  end

  # ── a track's people ─────────────────────────────────────────────────

  @doc "Who can reach this track."
  @spec list(User.t(), String.t()) :: {:ok, [Store.person()]} | {:error, :not_found}
  def list(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      {:ok, Store.people_of(track.id, project.user_id, project.id)}
    end
  end

  @doc """
  Invite somebody to a track by GitHub login.

  They need not already have signed in here: a username with no account is
  resolved against GitHub and the invitation waits on their account. What
  ravix cannot do is invite a *stranger*: sign-in is GitHub and this app
  never asks for an email, so there is no address to send anything to, and
  a row naming a login that has never appeared would be a permission
  granted to whoever claimed that name first.

  Admins only (ADR 0010). Returns the track's people, as `list/2` would. Refused on a
  project shared through its workspace (`workspace_sharing?/1`), where the
  Share dialog adds workspace members instead.
  """
  @spec add(User.t(), String.t(), String.t() | nil) ::
          {:ok, [Store.person()]} | {:error, reason()}
  def add(%User{} = user, track_id, login) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id, :admin),
         :ok <- links_kept(project),
         {:ok, found} <- resolve_login(login),
         :ok <- refuse_track_grade(found, project, track) do
      case found do
        %{user: %User{} = member} ->
          Store.add_member(track.id, member.id, user.id)

        %{user: nil} ->
          Store.add_invite(%{
            track_id: track.id,
            github_id: found.github_id,
            login: found.login,
            avatar_url: found.avatar_url,
            invited_by: user.id
          })
      end

      Ravix.Hub.publish(project.id, :people, track_id: track.id)
      {:ok, Store.people_of(track.id, project.user_id, project.id)}
    end
  end

  @doc """
  The owner removing somebody from a track, or somebody removing themselves.

  Both are the same row and the same effect, so they are the same function.
  The difference is only who may ask, and letting a member leave without
  going through the owner is the difference between a shared track and a
  summons.

  Returns the track's people, or `{:ok, :left}` when the caller has just
  removed their own access and there is no list left to hand back.
  """
  @spec remove(User.t(), String.t(), String.t()) ::
          {:ok, [Store.person()] | :left} | {:error, reason()}
  def remove(%User{} = user, track_id, login) do
    with {:ok, %{track: track, project: project, role: role, level: level}} <-
           Access.track_access(user, track_id) do
      wanted = strip_at(login)

      # An invitation that has not been taken up yet is cancelled rather
      # than removed: there is no membership to delete, only a promise to
      # withdraw. Admins only, because a pending person has no session to ask
      # with.
      if Access.allows?(level, :admin) and Store.remove_invite_by_login(track.id, wanted) do
        Ravix.Hub.publish(project.id, :people, track_id: track.id)
        {:ok, Store.people_of(track.id, project.user_id, project.id)}
      else
        remove_from_track(user, track, project, {role, level}, wanted)
      end
    end
  end

  defp remove_from_track(user, track, project, {role, level}, wanted) do
    with {:ok, target} <- find_person(wanted),
         :ok <- may_remove(level, user, target),
         :ok <- refuse_track_project_member(project, user, target, track) do
      # `remove_member/2` tells the hub; saying it again here would only make
      # every page on the project re-read twice.
      Store.remove_member(track.id, target.id)

      # The caller may have just removed their own access, in which case
      # there is nothing left to hand back: `:left` rather than a list they
      # cannot see.
      if target.id == user.id and role != :owner,
        do: {:ok, :left},
        else: {:ok, Store.people_of(track.id, project.user_id, project.id)}
    end
  end

  # ── roles (ADR 0010) ────────────────────────────────────────────────

  @doc """
  Change what somebody named on this track may do: `"read"`, `"write"` or
  `"admin"`. An admin of the track only, and never their own role -- nobody
  demotes themselves out of the dialog they are standing in, and nobody
  promotes themselves. The owner and a private track's creator are always
  admin and have no seat to change; somebody here by way of the project has
  their role in the project's people, and the sentence says so.

  A live page of the person changed hears `:people` and re-reads; every
  action they take is checked again against the new role anyway. Returns
  the track's people, as `list/2` would.
  """
  @spec set_role(User.t(), String.t(), String.t(), String.t()) ::
          {:ok, [Store.person()]} | {:error, reason()}
  def set_role(%User{} = user, track_id, login, role) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id, :admin),
         {:ok, role} <- parse_role(role),
         {:ok, target} <- find_person(strip_at(to_string(login))),
         :ok <- not_self(user, target),
         :ok <- seated_on_track(project, track, target, role) do
      {:ok, Store.people_of(track.id, project.user_id, project.id)}
    end
  end

  @doc """
  `set_role/4` one level up: a project member's role across every
  project-visible track and the project itself. The project's admins only.

  On a workspace project a live member of its workspace with no membership
  is given one (RAV-75, "Give a different role"): a direct grant, which
  takes precedence over the workspace's Write whether it is higher or
  lower. `remove_project/3` takes it away again.
  """
  @spec set_project_role(User.t(), String.t(), String.t(), String.t()) ::
          {:ok, [Store.person()]} | {:error, reason()}
  def set_project_role(%User{} = user, project_id, login, role) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id, :admin),
         {:ok, role} <- parse_role(role),
         {:ok, target} <- find_person(strip_at(to_string(login))),
         :ok <- not_self(user, target),
         :ok <- refuse_owner_role(project, target),
         :ok <- grant_project_role(project, target, role, user) do
      project_people(user, project)
    end
  end

  # A project member's role changes where it is. A member of the project's
  # workspace with none is given one (RAV-75, "Give a different role"): a
  # direct grant, which takes precedence over the workspace's default
  # whether it is higher or lower. Anybody else is not in the project.
  defp grant_project_role(project, target, role, user) do
    cond do
      Store.set_project_member_role(project.id, target.id, role) ->
        :ok

      Access.workspace_member?(project, target.id) ->
        case Store.grant_project_role(project, target.id, role, user.id) do
          :ok -> :ok
          {:error, :not_workspace_member} -> {:error, :not_found}
        end

      true ->
        {:error, :not_found}
    end
  end

  defp parse_role(role) when role in ["read", "write", "admin"],
    do: {:ok, String.to_existing_atom(role)}

  defp parse_role(role) when role in [:read, :write, :admin], do: {:ok, role}

  defp parse_role(_role),
    do: {:error, {:unprocessable, "invalid_role", "A role is Read, Write or Admin."}}

  defp not_self(%User{id: id}, %User{id: id}),
    do: {:error, {:unprocessable, "own_role", "You cannot change your own role."}}

  defp not_self(_user, _target), do: :ok

  defp refuse_owner_role(%Project{user_id: owner_id}, %User{id: owner_id}),
    do: {:error, {:unprocessable, "owner", "The owner is always an admin."}}

  defp refuse_owner_role(_project, _target), do: :ok

  defp seated_on_track(project, track, target, role) do
    cond do
      target.id == project.user_id ->
        refuse_owner_role(project, target)

      track.visibility == :private and Access.creator?(target, track) ->
        {:error, {:unprocessable, "creator", "Whoever made a private track is always its admin."}}

      Store.set_member_role(track.id, target.id, role) ->
        :ok

      Store.project_member?(project.id, target.id) ->
        {:error,
         {:conflict, "in_whole_project",
          "@#{target.login} is in this whole project. Change their role in the project's people."}}

      true ->
        {:error, :not_found}
    end
  end

  # ── selected workspace members (ADR 0009) ───────────────────────────

  @doc """
  Share a private track with one member of its workspace: a permission row
  (`Ravix.Tracks.TrackPermission`), ADR 0009's "selected workspace members".

  The creator only, on a private track in a workspace project, and only
  with `RAVIX_WORKSPACE_ACCESS` on -- while it is off this answers not found,
  as the workspace door does. Sharing is workspace-only: somebody who is
  not a live member of the track's workspace is refused with
  `:not_workspace_member`, and nobody is admitted to the workspace by it.
  Legacy seats and #299's invite links are `add/3` and the link routes,
  unchanged.
  """
  @spec share(User.t(), String.t(), String.t()) ::
          :ok | {:error, reason() | :not_workspace_member}
  def share(%User{} = user, track_id, user_id) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id),
         {:ok, _} <- Access.workspace_grant(user, project.workspace_id, :create_track),
         :ok <- Access.require_track_manager(role, user, track, "share this track"),
         :ok <- shareable(track),
         {:ok, _} <- workspace_member(project.workspace_id, user_id),
         :ok <- Store.add_permission(track.id, user_id, project.workspace_id, user.id) do
      Ravix.Hub.publish(project.id, :people, track_id: track.id)
      :ok
    end
  end

  @doc """
  Take a permission row away: the creator removing anybody, or a holder
  removing themselves. Never behind the switch, since taking access away
  is safe in either state. Their preview grants on the track go with it,
  and open pages hear `:people` on the project.
  """
  @spec unshare(User.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def unshare(%User{} = user, track_id, user_id) do
    with {:ok, %{track: track, role: role}} <- Access.track_access(user, track_id),
         :ok <-
           if(user_id == user.id,
             do: :ok,
             else: Access.require_track_manager(role, user, track, "stop sharing this track")
           ) do
      Store.remove_permission(track, user_id)
    end
  end

  @doc "Whom a track is shared with through permission rows. Anyone who reaches it may ask."
  @spec shared_with(User.t(), String.t()) :: {:ok, [User.t()]} | {:error, :not_found}
  def shared_with(%User{} = user, track_id) do
    with {:ok, %{track: track}} <- Access.track_access(user, track_id),
         do: {:ok, Store.permitted_on(track.id)}
  end

  # ── the Share dialog (ADR 0009 phase 5) ─────────────────────────────

  @doc """
  Whether a project's tracks are shared through its workspace, with the
  Share dialog, rather than through #299's invitations and links: the
  switch is on and the project is in a workspace. Anything with a
  `workspace_id` will do, a `Ravix.Projects.View` included. A legacy project
  keeps its invitations and links whatever the switch says.
  """
  @spec workspace_sharing?(map()) :: boolean()
  def workspace_sharing?(%{workspace_id: id}) when is_binary(id),
    do: Ravix.Config.workspace_access?()

  def workspace_sharing?(_project), do: false

  @doc """
  What the Share dialog shows for a track: who may change what, whom a
  private track is shared with, and the link. Anyone who reaches the track
  may read it; not found on a legacy project or with the switch off.
  """
  @spec sharing(User.t(), String.t()) :: {:ok, Sharing.t()} | {:error, :not_found}
  def sharing(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id),
         true <- workspace_sharing?(project) || {:error, :not_found},
         # ownership: `Access.track_access/2` admitted the caller to a track of
         # this workspace's project; the row is read for the name it shows.
         %{name: name} <- Ravix.Workspaces.Store.live_workspace(project.workspace_id),
         {:ok, reach} <- Access.track_people(user, track.id) do
      creator? = Access.creator?(user, track)
      holders = Map.get(Access.workspace_audience(project.id, [track.id]).permitted, track.id, [])

      {:ok,
       %Sharing{
         track_id: track.id,
         url: "#{Ravix.Config.public_url()}/p/#{project.id}/t/#{track.id}",
         workspace: name,
         visibility: track.visibility,
         private_allowed: track.sandbox_layout == :dedicated,
         set_visibility: creator?,
         manage_people:
           track.visibility == :private and
             Access.require_track_manager(role, user, track, "share") == :ok,
         holders: Enum.map(holders, &Store.present_person/1),
         access:
           Enum.map(reach, fn {u, level, source} -> {Store.present_person(u), level, source} end),
         consent: if(consent_pending?(user, track), do: Ravix.Tracks.billing_notice_text(user))
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The Share dialog's @-mention list: live members of the track's workspace
  whose login or name starts with `q`, less the creator, the caller and
  anyone already shared with. At most eight. Only for whoever may share
  the track (`share/3`), so nobody learns the workspace's members from a
  track they merely read.
  """
  @spec share_candidates(User.t(), String.t(), String.t() | nil) ::
          {:ok, [profile()]} | {:error, reason()}
  def share_candidates(%User{} = user, track_id, q) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id),
         {:ok, _} <- Access.workspace_grant(user, project.workspace_id, :create_track),
         :ok <- Access.require_track_manager(role, user, track, "share this track"),
         :ok <- shareable(track) do
      prefix = q |> to_string() |> String.trim() |> strip_at() |> String.slice(0, 60)
      except = [user.id, track.created_by | Enum.map(Store.permitted_on(track.id), & &1.id)]

      # ownership: `Access.track_access/2`, `Access.workspace_grant/3` and the
      # manager check above admitted the caller to share this track.
      {:ok,
       project.workspace_id
       |> Ravix.Workspaces.Store.search_members(prefix, Enum.reject(except, &is_nil/1), 8)
       |> Enum.map(&Store.present_person/1)}
    end
  end

  @doc """
  `share/3` by login, as the Share dialog picks people. Anybody who is not
  a live member of the track's workspace is refused with a sentence naming
  the workspace -- an unknown login and a stranger alike, so the box does
  not say which logins have accounts here. On a creator-billed track the
  creator's first share, made with the note in front of them, records it
  as shown (`consent_sharing/2`).
  """
  @spec share_login(User.t(), String.t(), String.t() | nil) :: :ok | {:error, reason()}
  def share_login(%User{} = user, track_id, login) do
    login = login |> to_string() |> String.slice(0, 80) |> String.trim() |> strip_at()

    # ownership: a login the creator picked; `share/3` puts the caller through
    # `Access.track_access/2` before the row is read for anything but its id.
    target = if login == "", do: nil, else: Ravix.Accounts.Store.user_by_login(login)

    case share(user, track_id, (target && target.id) || "") do
      :ok ->
        consent_sharing(user, track_id)

      {:error, :not_workspace_member} ->
        {:error,
         {:unprocessable, "not_workspace_member",
          "@#{login} is not a member of this track's workspace. Invite them to the workspace first."}}

      error ->
        error
    end
  end

  @doc "`unshare/3` by login: the creator removing a holder, or a holder leaving."
  @spec unshare_login(User.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def unshare_login(%User{} = user, track_id, login) do
    with {:ok, _} <- Access.track_access(user, track_id),
         {:ok, target} <- find_person(strip_at(to_string(login))) do
      unshare(user, track_id, target.id)
    end
  end

  @doc """
  The creator acknowledging RAV-17's one-time note -- collaborators'
  prompts on this track use their subscription -- in the Share dialog.
  It is the note `Ravix.Tracks.billing_notice/2` shows on the track page,
  recorded on the same column, so whichever surface shows it first, it is
  shown once. A no-op for anybody else and on a track its creator does not
  pay for.
  """
  @spec consent_sharing(User.t(), String.t()) :: :ok | {:error, :not_found}
  def consent_sharing(%User{} = user, track_id) do
    with {:ok, %{track: track}} <- Access.track_access(user, track_id) do
      # ownership: `Access.track_access/2` admitted this user, the track's payer.
      if consent_pending?(user, track), do: Ravix.Tracks.Store.mark_billing_notice(track.id)
      :ok
    end
  end

  # The creator of a track they pay for (RAV-17), not yet shown the note.
  defp consent_pending?(user, track) do
    Access.creator?(user, track) and Track.creator_billed?(track) and
      track.payer_user_id == user.id and is_nil(track.billing_notice_at)
  end

  # ── the cutover's Inbox notes ────────────────────────────────────────

  @typedoc "An Inbox note from the invite-link cutover; see `Ravix.People.AccessNotice`."
  @type notice :: %{
          id: String.t(),
          project_id: String.t(),
          track_id: String.t(),
          track_title: String.t(),
          workspace_id: String.t(),
          revoked: [String.t()],
          withdrawn: [String.t()],
          at: DateTime.t()
        }

  @doc """
  The caller's undismissed access notices, newest first: people who lost
  access to a track of theirs when its links were retired. Only on tracks
  the caller still reaches.
  """
  @spec notices(User.t()) :: [notice()]
  def notices(%User{id: user_id} = user) when is_binary(user_id) do
    # ownership: no door -- the rows are this caller's own notices; each
    # track is then checked through `Access.track_access/2` before it is shown.
    for {notice, track} <- Store.notices_for(user_id),
        match?({:ok, _}, Access.track_access(user, track.id)) do
      %{
        id: notice.id,
        project_id: track.project_id,
        track_id: track.id,
        track_title: track.title,
        workspace_id: notice.workspace_id,
        revoked: notice.revoked_logins,
        withdrawn: notice.withdrawn_logins,
        at: notice.created_at
      }
    end
  end

  @doc "Dismiss one of the caller's own access notices."
  @spec dismiss_notice(User.t(), String.t()) :: :ok | {:error, :not_found}
  def dismiss_notice(%User{id: user_id}, id) when is_binary(id) do
    # ownership: no door -- the update is limited to the caller's own rows.
    if Store.dismiss_notice(id, user_id), do: :ok, else: {:error, :not_found}
  end

  defp shareable(%{visibility: :private}), do: :ok

  defp shareable(_track),
    do:
      {:error,
       {:unprocessable, "not_private",
        "Only a private track is shared with selected members; the others are already visible to the workspace."}}

  defp workspace_member(workspace_id, user_id) do
    case Access.workspace_access(%User{id: user_id}, workspace_id) do
      {:ok, access} -> {:ok, access}
      {:error, :not_found} -> {:error, :not_workspace_member}
    end
  end

  # Somebody here by way of the *project* is not the track dialog's to
  # remove. Silently widening one click into "out of every track on this
  # machine" would be the most surprising thing either dialog could do, so
  # it is named and refused, and the sentence says where the control
  # actually is.
  defp refuse_track_project_member(_project, _user, _target, %{visibility: :private}), do: :ok

  defp refuse_track_project_member(project, user, target, _track),
    do: refuse_project_member(project, user, target)

  defp refuse_project_member(project, user, target) do
    if Store.project_member?(project.id, target.id) do
      message =
        if target.id == user.id,
          do:
            "You are in this whole project, not just this track. Leave the project to give up its tracks.",
          else:
            "@#{target.login} is in this whole project, not just this track. Remove them from the project's people to take this away."

      {:error, {:conflict, "in_whole_project", message}}
    else
      :ok
    end
  end

  # ── the same three, one level up ──────────────────────────────────────

  @doc "Who can reach every track on this project."
  @spec list_project(User.t(), String.t()) :: {:ok, [Store.person()]} | {:error, :not_found}
  def list_project(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id),
         do: project_people(user, project)
  end

  # Everyone who reaches the project, at their level and with where it comes
  # from, as `Access.project_people/2` decides it (RAV-75), and the
  # invitations nobody has taken up yet after them. A direct grant held by a
  # member of the project's workspace says what removing it falls back to.
  defp project_people(user, project) do
    with {:ok, reach} <- Access.project_people(user, project.id) do
      people =
        Enum.map(reach, fn {person, level, source} ->
          %{
            Person.new(person, via_of(source))
            | role: level,
              source: source,
              fallback: fallback(project, person, source)
          }
        end)

      pending =
        project.id
        |> Store.project_invites_of()
        |> Enum.map(&Person.pending(&1.login, &1.avatar_url))

      {:ok, people ++ pending}
    end
  end

  @typedoc "What a workspace project's people list opens with; see `workspace_base/2`."
  @type workspace_base :: %{
          workspace: String.t(),
          members: non_neg_integer(),
          level: Access.level()
        }

  @doc """
  The base role on a project shared through its workspace (RAV-75): the
  workspace's name, how many live members it has, and the level each of
  them gets without a direct grant. Nil on a project that is not shared
  that way. Anyone in the project may ask.
  """
  @spec workspace_base(User.t(), String.t()) ::
          {:ok, workspace_base() | nil} | {:error, :not_found}
  def workspace_base(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id) do
      # ownership: `Access.project_access/2` admitted the caller to this
      # workspace's project; the workspace is read for its name and size.
      with true <- workspace_sharing?(project),
           %{name: name} <- Ravix.Workspaces.Store.live_workspace(project.workspace_id) do
        members = Ravix.Workspaces.Store.live_members(project.workspace_id)
        {:ok, %{workspace: name, members: length(members), level: :write}}
      else
        _ -> {:ok, nil}
      end
    end
  end

  defp via_of(:owner), do: :owner
  defp via_of(:direct), do: :project
  defp via_of(:workspace), do: :workspace

  defp fallback(project, person, :direct),
    do: if(Access.workspace_member?(project, person.id), do: :write)

  defp fallback(_project, _person, _source), do: nil

  @doc """
  Invite somebody to the whole project.

  The same act as the track's, one level up, and the same two outcomes: a
  membership for somebody who has signed in here, an invitation waiting on
  GitHub for somebody who has not. What differs is what it grants, and that
  difference is the dialog's to explain; see the module documentation.

  The owner and the project's admins (ADR 0010). Anybody else who could
  invite could hand out the machine they were lent; an admin is somebody the
  owner chose to trust with exactly that.

  Refused on a project shared through its workspace (`workspace_sharing?/1`,
  RAV-32): people join the workspace from its members page instead, and
  nobody outside it is let onto its machine.
  """
  @spec add_project(User.t(), String.t(), String.t() | nil) ::
          {:ok, [Store.person()]} | {:error, reason()}
  def add_project(%User{} = user, project_id, login) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id, :admin),
         :ok <- project_links_kept(project),
         {:ok, found} <- resolve_login(login),
         :ok <- refuse_owner(found, project, "That is the owner of this project.") do
      # `add_project_member/3` is a promotion: any track rows they held on
      # this project go with it, so the list cannot end up showing one
      # person at two grades.
      case found do
        %{user: %User{} = member} ->
          Store.add_project_member(project.id, member.id, user.id)

        %{user: nil} ->
          Store.add_project_invite(%{
            project_id: project.id,
            github_id: found.github_id,
            login: found.login,
            avatar_url: found.avatar_url,
            invited_by: user.id
          })
      end

      # No `track_id`: this changed who is on every track of the project at
      # once, and the page re-reads the rail rather than one row.
      Ravix.Hub.publish(project.id, :people)
      project_people(user, project)
    end
  end

  @doc """
  The owner removing somebody from a project, or somebody leaving.

  This gives up project-visible tracks, including invitations superseded
  by promotion. Private track memberships and creator access are revoked too, together with
  outstanding work and invitations issued by the removed person.

  Returns the project's people, or `{:ok, :left}` when the caller has just
  removed their own access.

  A live member of the project's workspace is not removed: they reach it
  through the workspace whatever this says, so only their direct grant goes
  and they fall back to the workspace's level (RAV-75).
  """
  @spec remove_project(User.t(), String.t(), String.t()) ::
          {:ok, [Store.person()] | :left} | {:error, reason()}
  def remove_project(%User{} = user, project_id, login) do
    with {:ok, %{project: project, role: role, level: level}} <-
           Access.project_access(user, project_id) do
      wanted = strip_at(login)

      # As on a track: an invitation nobody has taken up is withdrawn rather
      # than removed. Admins only, because a pending person has no session to
      # ask with.
      if Access.allows?(level, :admin) and
           Store.remove_project_invite_by_login(project.id, wanted) do
        Ravix.Hub.publish(project.id, :people)
        project_people(user, project)
      else
        remove_from_project(user, project, {role, level}, wanted)
      end
    end
  end

  defp remove_from_project(user, project, {role, level}, wanted) do
    with {:ok, target} <- find_person(wanted),
         :ok <- refuse_removing_owner(project, target),
         :ok <- may_remove(level, user, target) do
      if Access.workspace_member?(project, target.id) do
        # RAV-75: a member of the project's workspace reaches it through the
        # workspace whatever this says. What goes is their direct grant, and
        # they fall back to the workspace's default; their tracks stay.
        Store.drop_project_grant(project.id, target.id)
        project_people(user, project)
      else
        leave_project(user, project, role, target)
      end
    end
  end

  defp leave_project(user, project, role, target) do
    Store.remove_project_member(project.id, target.id)

    # Nothing left to hand back to somebody who just removed their own
    # access. The caller has to leave rather than re-render.
    if target.id == user.id and role != :owner,
      do: {:ok, :left},
      else: project_people(user, project)
  end

  # ── resolving a typed username ───────────────────────────────────────

  # A typed username, resolved to whoever it names.
  #
  # Two answers, because ravix has two kinds of invitation and the
  # difference is not a detail: somebody who has signed in here is a row we
  # can grant access to now, and somebody who has not is an account on
  # GitHub that an invitation has to *wait* for. Shared by both grains of
  # invite so the error sentences, and the GitHub lookup that produces the
  # good ones, cannot drift between the track dialog and the project dialog.
  defp resolve_login(raw) do
    login = raw |> to_string() |> String.slice(0, 80) |> String.trim() |> strip_at()

    cond do
      login == "" ->
        {:error, {:unprocessable, "no_login", "Give a GitHub username."}}

      # Somebody who has signed in here joins immediately.
      #
      # ownership: a login an owner typed into the invite box, after `add/3`
      # or `add_project/3` put them through `Access.track_access/2` or
      # `Access.project_access/2`. The row is read to learn whom they mean.
      existing = Ravix.Accounts.Store.user_by_login(login) ->
        {:ok,
         %{
           user: existing,
           github_id: existing.github_id,
           login: existing.login,
           avatar_url: existing.avatar_url
         }}

      true ->
        # Anybody else is invited on GitHub's account rather than on ours.
        # The invitation waits for them to sign in, and is stored against
        # the numeric id rather than the name they had today.
        lookup_on_github(login)
    end
  end

  defp lookup_on_github(login) do
    with {:ok, app} <- Ravix.Providers.github(),
         {:ok, account} <- Ravix.GitHub.user_by_login(app, login) do
      case account do
        nil ->
          {:error, {:unprocessable, "no_such_user", "There is no GitHub user called @#{login}."}}

        %{id: id} ->
          {:ok,
           %{
             user: nil,
             github_id: to_string(id),
             login: account.login,
             avatar_url: account.avatar_url
           }}
      end
    end
  end

  defp refuse_owner(%{github_id: github_id}, %Project{user_id: owner_id}, message) do
    # ownership: the project's own `user_id`, compared with the person being
    # invited; `add/3` holds `project` from `Access.track_access/2` and
    # `add_project/3` from `Access.project_access/2`.
    case Ravix.Accounts.Store.get_user(owner_id) do
      %User{github_id: ^github_id} -> {:error, {:unprocessable, "already_owner", message}}
      _ -> :ok
    end
  end

  # Somebody already in the whole project, or on their way into it, reaches
  # this track by the wider row. Writing a narrower one on top would be a
  # no-op that the list cannot show and that `add_project_member/3` would
  # delete on the next promotion anyway. Refused rather than silently
  # ignored, because the owner is entitled to know their click did nothing.
  defp refuse_track_grade(_found, _project, %{visibility: :private}), do: :ok

  defp refuse_track_grade(found, project, _track) do
    with :ok <- refuse_owner(found, project, "That is the owner of this project."),
         do: refuse_wider_grade(found, project)
  end

  defp refuse_wider_grade(found, %Project{} = project) do
    cond do
      match?(%User{}, found.user) and Store.project_member?(project.id, found.user.id) ->
        {:error,
         {:unprocessable, "already_in_project",
          "@#{found.login} is in this whole project already, so they are already in this track."}}

      Store.has_project_invite?(project.id, found.github_id) ->
        {:error,
         {:unprocessable, "already_in_project",
          "@#{found.login} is already invited to this whole project, so they will reach this track too."}}

      true ->
        :ok
    end
  end

  defp find_person(login) do
    # ownership: a login typed by somebody removing a person, who came
    # through `Access.track_access/2` in `remove/3` or `Access.project_access/2`
    # in `remove_project/3`. Nil for an ambiguous login, so nobody is removed
    # on a guess.
    case Ravix.Accounts.Store.user_by_login(login) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  # Anybody may leave; only an admin (ADR 0010) removes somebody else.
  defp may_remove(_level, %User{id: id}, %User{id: id}), do: :ok
  defp may_remove(:admin, _user, _target), do: :ok

  defp may_remove(_level, _user, _target),
    do: {:error, {:forbidden, "Only an admin can remove somebody else."}}

  defp refuse_removing_owner(%Project{user_id: owner_id}, %User{id: owner_id}),
    do: {:error, {:unprocessable, "owner", "The owner is always in the project."}}

  defp refuse_removing_owner(_project, _target), do: :ok

  defp strip_at("@" <> login), do: login
  defp strip_at(login) when is_binary(login), do: login

  # ADR 0009 phase 5: a workspace project's tracks are shared with its
  # members from the Share dialog. Invitations by login and invite links are
  # retired there, so nothing new is handed out that could outlive a
  # membership or admit somebody from outside the workspace.
  defp links_kept(project) do
    if workspace_sharing?(project),
      do:
        {:error,
         {:unprocessable, "workspace_sharing",
          "This track is shared with members of its workspace. Use Share to add people."}},
      else: :ok
  end

  # RAV-32: the same, one level up. A project link or invitation admitted
  # anybody to every track on a workspace project, members of the workspace
  # or not; the workspace's own members page is how somebody joins now.
  defp project_links_kept(project) do
    if workspace_sharing?(project),
      do:
        {:error,
         {:unprocessable, "workspace_sharing",
          "This project is shared with members of its workspace. Invite people to the workspace, and use Share on a track to add them to it."}},
      else: :ok
  end

  # ── a plain link (ADR 0010) ──────────────────────────────────────────

  @doc """
  The track's own address, for anybody who can see it to copy. Not an
  invitation: it opens the track only for somebody who already reaches it,
  and anybody else gets the same not found a stranger does. Always there,
  unlike an invite link, whose address is shown once.
  """
  @spec track_url(User.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def track_url(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id),
         do: {:ok, "#{Ravix.Config.public_url()}/p/#{project.id}/t/#{track.id}"}
  end

  @doc "The project's own address, on the same terms as `track_url/2`."
  @spec project_url(User.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def project_url(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id),
         do: {:ok, "#{Ravix.Config.public_url()}/p/#{project.id}"}
  end

  # ── the other way in: a link ─────────────────────────────────────────

  @doc "Whether a track link is out, never the link itself. Owner-only."
  @spec link(User.t(), String.t()) :: {:ok, invite_link() | nil} | {:error, reason()}
  def link(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id, :admin) do
      # The URL is deliberately absent. Only the hash is stored, so it
      # genuinely cannot be shown again, which is worth being honest about
      # rather than implying it was lost. A retired link is no link.
      if workspace_sharing?(project),
        do: {:ok, nil},
        else: {:ok, describe_link(Store.link_of(track.id))}
    end
  end

  @doc """
  Mint a track link, replacing whatever was out.

  Minting is also the revoke: there is one row per track, so a new link
  silently kills the old one. That is the behaviour people expect from a
  "regenerate" button and the one they do not expect from a "create"
  button, so the UI says which it is doing. Owner-only. The returned `url`
  is the only time the link is ever shown. Refused on a project shared
  through its workspace, whose tracks have no invite links (ADR 0009).
  """
  @spec mint_link(User.t(), String.t()) :: {:ok, invite_link()} | {:error, reason()}
  def mint_link(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id, :admin),
         :ok <- links_kept(project) do
      token = Ravix.Crypto.random_token()
      Store.put_link(track.id, Ravix.Crypto.sha256(token), user.id, @link_ttl_ms)
      {:ok, minted(Store.link_of(track.id), token)}
    end
  end

  @doc """
  Revoke a track link: nobody new gets in on it.

  Deliberately not a removal: people who already came in on this link stay,
  and the owner takes them out by name if that is what they meant. A revoke
  that silently evicted half a track would be the more surprising of the
  two. Owner-only.
  """
  @spec drop_link(User.t(), String.t()) :: :ok | {:error, reason()}
  def drop_link(%User{} = user, track_id) do
    with {:ok, %{track: track}} <- Access.track_access(user, track_id, :admin) do
      Store.drop_link(track.id)
    end
  end

  @doc "Whether a project link is out, never the link itself. Owner-only."
  @spec project_link(User.t(), String.t()) :: {:ok, invite_link() | nil} | {:error, reason()}
  def project_link(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id, :admin) do
      # As `link/2`: a retired link is no link.
      if workspace_sharing?(project),
        do: {:ok, nil},
        else: {:ok, describe_link(Store.project_link_of(project.id))}
    end
  end

  @doc """
  Mint a project link, replacing whatever was out. Owner-only. Refused on a
  project shared through its workspace, whose links are retired (RAV-32).
  """
  @spec mint_project_link(User.t(), String.t()) :: {:ok, invite_link()} | {:error, reason()}
  def mint_project_link(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id, :admin),
         :ok <- project_links_kept(project) do
      token = Ravix.Crypto.random_token()

      Store.put_project_link(
        project.id,
        Ravix.Crypto.sha256(token),
        user.id,
        @project_link_ttl_ms
      )

      {:ok, minted(Store.project_link_of(project.id), token)}
    end
  end

  @doc "Revoke a project link: nobody new gets in on it. Owner-only."
  @spec drop_project_link(User.t(), String.t()) :: :ok | {:error, reason()}
  def drop_project_link(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id, :admin) do
      Store.drop_project_link(project.id)
    end
  end

  defp describe_link(nil), do: nil

  defp describe_link(%{created_at: created_at, expires_at: expires_at}),
    do: %InviteLink{url: nil, created_at: created_at, expires_at: expires_at}

  defp minted(%{created_at: created_at, expires_at: expires_at}, token) do
    %InviteLink{
      url: "#{Ravix.Config.public_url()}/j/#{token}",
      created_at: created_at,
      expires_at: expires_at
    }
  end

  @doc """
  A link token, spent: the caller joins whatever it opens and is told where
  to land (`GET /j/:token`, once the person is signed in).

  One function for both kinds because `/j/:token` is one route: the token
  says which it is, and a browser holding one has no idea and should not
  need to. Tracks are tried first only because they are the older and
  narrower of the two; the hashes are unique across both tables, so the
  order is arbitrary rather than load-bearing.

  `:error` when the link is unknown, revoked, expired, or points at
  something that has since closed. `:retired` for a track or project link
  on a project shared through its workspace (ADR 0009 phase 5, RAV-32): it
  admits nobody, and the page says to ask the project's owner for a
  workspace invitation. Takes a user id rather than a
  user because the sign-in callback has only just created the row.
  """
  @spec claim_link(String.t(), String.t()) :: {:ok, String.t()} | :error | :retired
  def claim_link(user_id, token) do
    hash = Ravix.Crypto.sha256(token)

    case Store.track_for_link(hash) do
      %Track{} = track -> redeem_track(user_id, track)
      nil -> redeem_project(user_id, Store.project_for_link(hash))
    end
  end

  @typedoc "What a link opens, before it is claimed; see `Ravix.People.LinkTarget`."
  @type link_target :: LinkTarget.t()

  @doc """
  What a link opens, without claiming it.

  `claim_link/2` is this lookup followed by a write. This is the half a
  confirmation page needs, so that following an invite link is a question
  rather than an act: `GET /j/:token` used to add the membership, and a GET
  carries no CSRF token and is reachable by any page that can navigate a
  signed-in browser (#16).

  `:error` for a link that is gone, expired, closed or was never real -- the
  same answer `claim_link/2` gives for each, so what the page says cannot tell
  a bad token from a good one.

  The optional viewer affects only the project label: its owner sees the bare
  name; everyone else sees the owner prefix. The hash still authorizes the read.

  `:retired` for a track or project link whose project is now shared
  through its workspace, as `claim_link/2` answers it.

  `invited_by` is whoever minted the link, by login. Worth naming: an invitation
  is a claim about who is asking, and the one piece of it a stranger cannot
  forge is the account that actually holds the project.
  """
  @spec link_target(String.t()) :: {:ok, link_target()} | :error | :retired
  @spec link_target(String.t(), User.t() | nil) :: {:ok, link_target()} | :error | :retired
  def link_target(token, user \\ nil) do
    hash = Ravix.Crypto.sha256(token)

    case Store.track_for_link(hash) do
      %Track{} = track -> track_target(track, hash, user)
      nil -> project_target(Store.project_for_link(hash), hash, user)
    end
  end

  defp track_target(%Track{} = track, hash, user) do
    # ownership: the link's hash is the authorization here, and it was just
    # matched against this track's row.
    case Store.live_project(track.project_id) do
      %Project{} = project ->
        if workspace_sharing?(project),
          do: :retired,
          else: {:ok, track_link_target(project, track, hash, user)}

      _ ->
        :error
    end
  end

  defp track_link_target(project, track, hash, user) do
    %LinkTarget{
      kind: :track,
      project: project.name,
      project_view: invite_project(project, user),
      track: track.title,
      invited_by: Store.minted_by(TrackLink, :track_id, track.id, hash)
    }
  end

  defp project_target(nil, _hash, _user), do: :error

  defp project_target(%Project{} = project, hash, user) do
    if workspace_sharing?(project),
      do: :retired,
      else: {:ok, project_link_target(project, hash, user)}
  end

  defp project_link_target(project, hash, user) do
    %LinkTarget{
      kind: :project,
      project: project.name,
      project_view: invite_project(project, user),
      track: nil,
      invited_by: Store.minted_by(ProjectLink, :project_id, project.id, hash)
    }
  end

  # ownership: the invite hash matched the live project or one of its tracks
  # in `link_target/2`. It authorizes this label before membership is claimed.
  defp invite_project(project, user) do
    access = if user && user.id == project.user_id, do: :owner, else: nil
    Ravix.Projects.present(project, access, Machine.none())
  end

  defp redeem_track(user_id, %Track{} = track) do
    # ownership: as `track_target/2` -- holding the link is what admits this
    # caller, and `Store.track_for_link/1` has already matched it.
    case Store.live_project(track.project_id) do
      %Project{} = project ->
        # A workspace project's links are retired: holding one admits
        # nobody, whatever the link row says (ADR 0009 phase 5).
        if workspace_sharing?(project), do: :retired, else: seat_by_link(user_id, track, project)

      _ ->
        :error
    end
  end

  defp seat_by_link(user_id, track, project) do
    # Somebody already in the whole project needs no row and gets none:
    # a track membership written here would outlive their project
    # membership and quietly leave them one branch after being removed.
    if track.visibility == :private or
         (project.user_id != user_id and not Store.project_member?(project.id, user_id)),
       do: Store.add_member(track.id, user_id, "link")

    Ravix.Hub.publish(project.id, :people, track_id: track.id)
    {:ok, "/p/#{project.id}/t/#{track.id}"}
  end

  defp redeem_project(_user_id, nil), do: :error

  # RAV-32: as a track link, a workspace project's link admits nobody,
  # workspace member or not. People who came in on one before stay.
  defp redeem_project(user_id, %Project{} = project) do
    if workspace_sharing?(project), do: :retired, else: seat_project_by_link(user_id, project)
  end

  defp seat_project_by_link(user_id, project) do
    if project.user_id != user_id, do: Store.add_project_member(project.id, user_id, "link")
    Ravix.Hub.publish(project.id, :people)
    # The project rather than one of its tracks: this link did not name
    # one, and picking a track for somebody is picking which of several
    # conversations they have walked into.
    {:ok, "/p/#{project.id}"}
  end
end
