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

    **A project member** gets every track on that project, the ones open
    now and the ones opened tomorrow, and may cut tracks of their own. A
    project you were let into where you cannot start a line of work is only
    a bundle of track invitations under a grander name.

  Neither of them gets the project's **controls**: settings, packages,
  secrets, rebuild, delete. That line is the one thing both memberships
  have in common and it is drawn in `Ravix.Accounts.Access`: `project_of`
  for the machine, `project_access` for the work on it, `track_access` for
  one piece of the work.

  **One person holds one grade of access to a project.** Inviting somebody
  to the whole project deletes any track rows they held on it, and inviting
  a project member to a single track is refused as the no-op it is. The
  corollary is the surprising half and is said in the dialog: removing
  somebody from a project takes away every track on it, including one they
  were named on separately beforehand. The alternative is a narrower row
  that survives invisibly, which is worse, because it is invisible at
  exactly the moment somebody is trying to revoke access. `add_project_member/3`
  is where that is enforced, so the three ways in cannot disagree about it.

  ## What sharing actually costs

  It is worth being exact, because the invite dialogs say it and this is
  where the sentence is true or not.

  A track is a shell on a machine that also holds every *other* track. The
  worktrees are separate directories, and the agent is told three times
  over to stay in its own, but that is a rule the agent follows, not a
  boundary the kernel enforces. Somebody who can prompt a track can ask the
  agent to read a sibling directory, and it may do it. They can also ask it
  to print the environment, which on a project with environment secrets
  means those secrets.

  Which is the honest reason project-level sharing is not the leap it looks
  like: a track invitation *already* costs most of what a project invitation
  costs, because they run on one box. What the wider one adds is the
  ability to read the other transcripts and to open tracks: real, and worth
  a separate act by the owner, but not a different order of trust.

  What neither can do is reach the project's controls. The one worth
  knowing is the credential: the clone token lives in the vault and never
  lands on the machine, so no member can print it. The machine does not
  have it to print.

  ## Shape of this module

  The first half is the routes of `server/people.ts`: every function takes
  the signed-in `%Ravix.Accounts.User{}` and goes through one of the doors
  in `Ravix.Accounts.Access` before touching a row. The second half is the
  membership slice of `server/db.ts`: row operations with no user argument,
  for a caller that has already established access (this module's own
  routes, the sign-in that claims invitations, the access doors themselves,
  the track list reading read markers). They are named as the contract
  names them rather than with an `_unsafe_` prefix because other contexts
  call them by those names; treat every function below "Rows" as unscoped.
  """

  import Ecto.Query

  alias Ravix.Accounts.{Access, User}
  alias Ravix.Projects.{Project, ProjectInvite, ProjectLink, ProjectMember}
  alias Ravix.Repo
  alias Ravix.Tracks.{Track, TrackInvite, TrackLink, TrackMember, TrackRead}

  @typedoc """
  The `Person` of `shared/api.ts`: only what GitHub already publishes about
  somebody. `via` says which row grants a track (present in a track's list
  only); `pending` marks an invitation nobody has taken up yet.
  """
  @type person :: %{
          required(:login) => String.t(),
          required(:name) => String.t() | nil,
          required(:avatar_url) => String.t() | nil,
          optional(:via) => :project | :track,
          optional(:pending) => true
        }

  @typedoc "The `InviteLink` of `shared/api.ts`. `url` is only ever present at the moment of minting."
  @type invite_link :: %{
          url: String.t() | nil,
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @typedoc "An invitation row, as the people lists read it."
  @type invite :: %{github_id: String.t(), login: String.t(), avatar_url: String.t() | nil}

  @type reason ::
          :not_found
          | {:forbidden, String.t()}
          | {:conflict, String.t(), String.t()}
          | {:unprocessable, String.t(), String.t()}
          | {:unavailable, String.t()}
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

  @no_github "This Ravix deployment has no GitHub App configured, so it cannot see repositories."

  # ── the invite box ───────────────────────────────────────────────────

  @doc """
  The invite box's autocomplete (`GET /api/users?q=`).

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
  @spec search(User.t(), String.t() | nil) :: [person()]
  def search(%User{} = user, q) do
    q = q |> to_string() |> String.trim()

    # One character is a fine query for a login; zero is a request for the
    # whole userbase, which is the one thing this should not hand over.
    if q == "" do
      []
    else
      q
      |> String.slice(0, 60)
      |> Ravix.Accounts.search_users(user.id)
      |> Enum.map(&present_person/1)
    end
  end

  # ── a track's people ─────────────────────────────────────────────────

  @doc "Who can reach this track (`GET /api/tracks/:id/people`)."
  @spec list(User.t(), String.t()) :: {:ok, [person()]} | {:error, :not_found}
  def list(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      {:ok, people_of(track.id, project.user_id, project.id)}
    end
  end

  @doc """
  Invite somebody to a track by GitHub login (`POST /api/tracks/:id/people`).

  They need not already have signed in here: a username with no account is
  resolved against GitHub and the invitation waits on their account. What
  ravix cannot do is invite a *stranger*: sign-in is GitHub and this app
  never asks for an email, so there is no address to send anything to, and
  a row naming a login that has never appeared would be a permission
  granted to whoever claimed that name first.

  Owner-only. Returns the track's people, as `list/2` would.
  """
  @spec add(User.t(), String.t(), String.t() | nil) :: {:ok, [person()]} | {:error, reason()}
  def add(%User{} = user, track_id, login) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id),
         :ok <- Access.require_owner(role, "invite people to a track"),
         {:ok, found} <- resolve_login(login),
         :ok <-
           refuse_owner(
             found,
             project,
             "That is the owner of this project. They are already in every track of it."
           ),
         :ok <- refuse_wider_grade(found, project) do
      case found do
        %{user: %User{} = member} ->
          add_member(track.id, member.id, user.id)

        %{user: nil} ->
          add_invite(%{
            track_id: track.id,
            github_id: found.github_id,
            login: found.login,
            avatar_url: found.avatar_url,
            invited_by: user.id
          })
      end

      Ravix.Hub.publish(project.id, "people", %{track_id: track.id})
      {:ok, people_of(track.id, project.user_id, project.id)}
    end
  end

  @doc """
  The owner removing somebody from a track, or somebody removing themselves
  (`DELETE /api/tracks/:id/people/:login`).

  Both are the same row and the same effect, so they are the same function.
  The difference is only who may ask, and letting a member leave without
  going through the owner is the difference between a shared track and a
  summons.

  Returns the track's people, or `{:ok, :left}` when the caller has just
  removed their own access and there is no list left to hand back.
  """
  @spec remove(User.t(), String.t(), String.t()) :: {:ok, [person()] | :left} | {:error, reason()}
  def remove(%User{} = user, track_id, login) do
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id) do
      wanted = strip_at(login)

      # An invitation that has not been taken up yet is cancelled rather
      # than removed: there is no membership to delete, only a promise to
      # withdraw. Owner-only, because a pending person has no session to ask
      # with.
      if role == :owner and remove_invite_by_login(track.id, wanted) do
        Ravix.Hub.publish(project.id, "people", %{track_id: track.id})
        {:ok, people_of(track.id, project.user_id, project.id)}
      else
        remove_from_track(user, track, project, role, wanted)
      end
    end
  end

  defp remove_from_track(user, track, project, role, wanted) do
    with {:ok, target} <- find_person(wanted),
         :ok <- may_remove(role, user, target),
         :ok <- refuse_project_member(project, user, target) do
      remove_member(track.id, target.id)
      Ravix.Hub.publish(project.id, "people", %{track_id: track.id})

      # The caller may have just removed their own access, in which case
      # there is nothing left to hand back: `:left` rather than a list they
      # cannot see.
      if target.id == user.id and role != :owner,
        do: {:ok, :left},
        else: {:ok, people_of(track.id, project.user_id, project.id)}
    end
  end

  # Somebody here by way of the *project* is not the track dialog's to
  # remove. Silently widening one click into "out of every track on this
  # machine" would be the most surprising thing either dialog could do, so
  # it is named and refused, and the sentence says where the control
  # actually is.
  defp refuse_project_member(project, user, target) do
    if project_member?(project.id, target.id) do
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

  # ── the same three routes, one level up ──────────────────────────────

  @doc "Who can reach every track on this project (`GET /api/projects/:id/people`)."
  @spec list_project(User.t(), String.t()) :: {:ok, [person()]} | {:error, :not_found}
  def list_project(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id) do
      {:ok, project_people_of(project.id, project.user_id)}
    end
  end

  @doc """
  Invite somebody to the whole project (`POST /api/projects/:id/people`).

  The same act as the track's, one level up, and the same two outcomes: a
  membership for somebody who has signed in here, an invitation waiting on
  GitHub for somebody who has not. What differs is what it grants, and that
  difference is the dialog's to explain; see the module documentation.

  Owner-only, and there is no argument for widening it. A member who could
  invite could hand out the machine they were lent, and the owner would
  find out from the people list.
  """
  @spec add_project(User.t(), String.t(), String.t() | nil) ::
          {:ok, [person()]} | {:error, reason()}
  def add_project(%User{} = user, project_id, login) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         :ok <- Access.require_owner(role, "invite people to a project"),
         {:ok, found} <- resolve_login(login),
         :ok <- refuse_owner(found, project, "That is the owner of this project.") do
      # `add_project_member/3` is a promotion: any track rows they held on
      # this project go with it, so the list cannot end up showing one
      # person at two grades.
      case found do
        %{user: %User{} = member} ->
          add_project_member(project.id, member.id, user.id)

        %{user: nil} ->
          add_project_invite(%{
            project_id: project.id,
            github_id: found.github_id,
            login: found.login,
            avatar_url: found.avatar_url,
            invited_by: user.id
          })
      end

      # No `track_id`: this changed who is on every track of the project at
      # once, and the page re-reads the rail rather than one row.
      Ravix.Hub.publish(project.id, "people", %{})
      {:ok, project_people_of(project.id, project.user_id)}
    end
  end

  @doc """
  The owner removing somebody from a project, or somebody leaving
  (`DELETE /api/projects/:id/people/:login`).

  This gives up **every track on the project**, in one go and including
  any the person was named on individually before they were let into the
  whole thing; those rows were deleted when they were promoted. It is a
  bigger door than leaving one track, which is why the dialog asks twice
  and says so in the sentence above the button.

  Returns the project's people, or `{:ok, :left}` when the caller has just
  removed their own access.
  """
  @spec remove_project(User.t(), String.t(), String.t()) ::
          {:ok, [person()] | :left} | {:error, reason()}
  def remove_project(%User{} = user, project_id, login) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id) do
      wanted = strip_at(login)

      # As on a track: an invitation nobody has taken up is withdrawn rather
      # than removed. Owner-only, because a pending person has no session to
      # ask with.
      if role == :owner and remove_project_invite_by_login(project.id, wanted) do
        Ravix.Hub.publish(project.id, "people", %{})
        {:ok, project_people_of(project.id, project.user_id)}
      else
        remove_from_project(user, project, role, wanted)
      end
    end
  end

  defp remove_from_project(user, project, role, wanted) do
    with {:ok, target} <- find_person(wanted),
         :ok <- may_remove(role, user, target) do
      remove_project_member(project.id, target.id)
      Ravix.Hub.publish(project.id, "people", %{})

      # Nothing left to hand back to somebody who just removed their own
      # access. The caller has to leave rather than re-render.
      if target.id == user.id and role != :owner,
        do: {:ok, :left},
        else: {:ok, project_people_of(project.id, project.user_id)}
    end
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
      existing = Ravix.Accounts.user_by_login(login) ->
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
    with {:ok, app} <- require_github(),
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
    else
      {:error, :unconfigured} -> {:error, {:unavailable, @no_github}}
      {:error, _} = error -> error
    end
  end

  defp require_github do
    case Ravix.Config.github() do
      nil -> {:error, :unconfigured}
      app -> {:ok, app}
    end
  end

  defp refuse_owner(%{github_id: github_id}, %Project{user_id: owner_id}, message) do
    case Ravix.Accounts.get_user(owner_id) do
      %User{github_id: ^github_id} -> {:error, {:unprocessable, "already_owner", message}}
      _ -> :ok
    end
  end

  # Somebody already in the whole project, or on their way into it, reaches
  # this track by the wider row. Writing a narrower one on top would be a
  # no-op that the list cannot show and that `add_project_member/3` would
  # delete on the next promotion anyway. Refused rather than silently
  # ignored, because the owner is entitled to know their click did nothing.
  defp refuse_wider_grade(found, %Project{} = project) do
    cond do
      match?(%User{}, found.user) and project_member?(project.id, found.user.id) ->
        {:error,
         {:unprocessable, "already_in_project",
          "@#{found.login} is in this whole project already, so they are already in this track."}}

      has_project_invite?(project.id, found.github_id) ->
        {:error,
         {:unprocessable, "already_in_project",
          "@#{found.login} is already invited to this whole project, so they will reach this track too."}}

      true ->
        :ok
    end
  end

  defp find_person(login) do
    case Ravix.Accounts.user_by_login(login) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  defp may_remove(:owner, _user, _target), do: :ok
  defp may_remove(_role, %User{id: id}, %User{id: id}), do: :ok

  defp may_remove(_role, _user, _target),
    do: {:error, {:forbidden, "Only the owner of this project can remove somebody else."}}

  defp strip_at("@" <> login), do: login
  defp strip_at(login) when is_binary(login), do: login

  # ── the people lists ─────────────────────────────────────────────────

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

  Unscoped: the caller has already resolved the track through
  `Ravix.Accounts.Access.track_access/2`.
  """
  @spec people_of(String.t(), String.t(), String.t()) :: [person()]
  def people_of(track_id, owner_id, project_id) do
    wide = project_members_of(project_id)
    seen = MapSet.new(wide, & &1.id)
    narrow = track_id |> members_of() |> Enum.reject(&MapSet.member?(seen, &1.id))
    # Pending last, because they cannot read anything yet and the list is
    # mostly read to answer "who can see this".
    pending = track_id |> invites_of() |> Enum.map(&pending_person/1)

    owner_entry(owner_id) ++
      Enum.map(wide, &Map.put(present_person(&1), :via, :project)) ++
      Enum.map(narrow, &Map.put(present_person(&1), :via, :track)) ++
      pending
  end

  @doc """
  Everyone on a project, owner first: the same list one level up.

  Deliberately *not* a union with the track memberships underneath it. This
  list answers "who is in the project", and somebody named on one branch of
  it is not; showing them here would make the owner's own decision
  unreadable back to them, and would put a remove control beside a row
  that this dialog cannot remove.

  Unscoped: the caller has already resolved the project through
  `Ravix.Accounts.Access.project_access/2`.
  """
  @spec project_people_of(String.t(), String.t()) :: [person()]
  def project_people_of(project_id, owner_id) do
    members = project_id |> project_members_of() |> Enum.map(&present_person/1)
    pending = project_id |> project_invites_of() |> Enum.map(&pending_person/1)
    owner_entry(owner_id) ++ members ++ pending
  end

  @doc "The `Person` of `shared/api.ts` for a user row: login, name, avatar, nothing else."
  @spec present_person(User.t()) :: person()
  def present_person(%User{login: login, name: name, avatar_url: avatar_url}),
    do: %{login: login, name: name, avatar_url: avatar_url}

  defp pending_person(%{login: login, avatar_url: avatar_url}),
    do: %{login: login, name: nil, avatar_url: avatar_url, pending: true}

  defp owner_entry(owner_id) do
    case Ravix.Accounts.get_user(owner_id) do
      %User{} = owner -> [present_person(owner)]
      nil -> []
    end
  end

  # ── the other way in: a link ─────────────────────────────────────────

  @doc "Whether a track link is out, never the link itself (`GET /api/tracks/:id/link`). Owner-only."
  @spec link(User.t(), String.t()) :: {:ok, invite_link() | nil} | {:error, reason()}
  def link(%User{} = user, track_id) do
    with {:ok, %{track: track, role: role}} <- Access.track_access(user, track_id),
         :ok <- Access.require_owner(role, "see this track's invite link") do
      # The URL is deliberately absent. Only the hash is stored, so it
      # genuinely cannot be shown again, which is worth being honest about
      # rather than implying it was lost.
      {:ok, describe_link(link_of(track.id))}
    end
  end

  @doc """
  Mint a track link, replacing whatever was out (`POST /api/tracks/:id/link`).

  Minting is also the revoke: there is one row per track, so a new link
  silently kills the old one. That is the behaviour people expect from a
  "regenerate" button and the one they do not expect from a "create"
  button, so the UI says which it is doing. Owner-only. The returned `url`
  is the only time the link is ever shown.
  """
  @spec mint_link(User.t(), String.t()) :: {:ok, invite_link()} | {:error, reason()}
  def mint_link(%User{} = user, track_id) do
    with {:ok, %{track: track, role: role}} <- Access.track_access(user, track_id),
         :ok <- Access.require_owner(role, "make an invite link for a track") do
      token = Ravix.Crypto.random_token()
      put_link(track.id, Ravix.Crypto.sha256(token), user.id, @link_ttl_ms)
      {:ok, minted(link_of(track.id), token)}
    end
  end

  @doc """
  Revoke a track link (`DELETE /api/tracks/:id/link`): nobody new gets in on it.

  Deliberately not a removal: people who already came in on this link stay,
  and the owner takes them out by name if that is what they meant. A revoke
  that silently evicted half a track would be the more surprising of the
  two. Owner-only.
  """
  @spec drop_link(User.t(), String.t()) :: :ok | {:error, reason()}
  def drop_link(%User{} = user, track_id) do
    with {:ok, %{track: track, role: role}} <- Access.track_access(user, track_id),
         :ok <- Access.require_owner(role, "revoke this track's invite link") do
      drop_link(track.id)
    end
  end

  @doc "Whether a project link is out, never the link itself (`GET /api/projects/:id/link`). Owner-only."
  @spec project_link(User.t(), String.t()) :: {:ok, invite_link() | nil} | {:error, reason()}
  def project_link(%User{} = user, project_id) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         :ok <- Access.require_owner(role, "see this project's invite link") do
      {:ok, describe_link(project_link_of(project.id))}
    end
  end

  @doc "Mint a project link, replacing whatever was out (`POST /api/projects/:id/link`). Owner-only."
  @spec mint_project_link(User.t(), String.t()) :: {:ok, invite_link()} | {:error, reason()}
  def mint_project_link(%User{} = user, project_id) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         :ok <- Access.require_owner(role, "make an invite link for a project") do
      token = Ravix.Crypto.random_token()
      put_project_link(project.id, Ravix.Crypto.sha256(token), user.id, @project_link_ttl_ms)
      {:ok, minted(project_link_of(project.id), token)}
    end
  end

  @doc "Revoke a project link (`DELETE /api/projects/:id/link`): nobody new gets in on it. Owner-only."
  @spec drop_project_link(User.t(), String.t()) :: :ok | {:error, reason()}
  def drop_project_link(%User{} = user, project_id) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         :ok <- Access.require_owner(role, "revoke this project's invite link") do
      drop_project_link(project.id)
    end
  end

  defp describe_link(nil), do: nil

  defp describe_link(%{created_at: created_at, expires_at: expires_at}),
    do: %{url: nil, created_at: created_at, expires_at: expires_at}

  defp minted(%{created_at: created_at, expires_at: expires_at}, token) do
    %{
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
  something that has since closed. Takes a user id rather than a user
  because the sign-in callback has only just created the row.
  """
  @spec claim_link(String.t(), String.t()) :: {:ok, String.t()} | :error
  def claim_link(user_id, token) do
    hash = Ravix.Crypto.sha256(token)

    case track_for_link(hash) do
      %Track{} = track -> redeem_track(user_id, track)
      nil -> redeem_project(user_id, project_for_link(hash))
    end
  end

  defp redeem_track(user_id, %Track{} = track) do
    case Repo.get(Project, track.project_id) do
      %Project{archived_at: nil} = project ->
        # Somebody already in the whole project needs no row and gets none:
        # a track membership written here would outlive their project
        # membership and quietly leave them one branch after being removed.
        if project.user_id != user_id and not project_member?(project.id, user_id),
          do: add_member(track.id, user_id, "link")

        Ravix.Hub.publish(project.id, "people", %{track_id: track.id})
        {:ok, "/p/#{project.id}/t/#{track.id}"}

      _ ->
        :error
    end
  end

  defp redeem_project(_user_id, nil), do: :error

  defp redeem_project(user_id, %Project{} = project) do
    if project.user_id != user_id, do: add_project_member(project.id, user_id, "link")
    Ravix.Hub.publish(project.id, "people", %{})
    # The project rather than one of its tracks: this link did not name
    # one, and picking a track for somebody is picking which of several
    # conversations they have walked into.
    {:ok, "/p/#{project.id}"}
  end

  # ── Rows: who else is in a track ─────────────────────────────────────

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
  """
  @spec remove_member(String.t(), String.t()) :: :ok
  def remove_member(track_id, user_id) do
    Ravix.Previews.revoke(track_id, user_id)
    Ravix.Previews.revoke_agent(track_id, user_id)

    Repo.delete_all(
      from(m in TrackMember, where: m.track_id == ^track_id and m.user_id == ^user_id)
    )

    :ok
  end

  @doc "Whether `user_id` was named on this track. The owner is not: they own the project."
  @spec member?(String.t(), String.t()) :: boolean()
  def member?(track_id, user_id) do
    Repo.exists?(from(m in TrackMember, where: m.track_id == ^track_id and m.user_id == ^user_id))
  end

  @doc "Everyone invited to a track, oldest invitation first. Excludes the owner."
  @spec members_of(String.t()) :: [User.t()]
  def members_of(track_id) do
    Repo.all(
      from(m in TrackMember,
        join: u in assoc(m, :user),
        where: m.track_id == ^track_id,
        order_by: m.created_at,
        select: u
      )
    )
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

  # ── Rows: invitations to somebody who is not here yet ────────────────

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
  def invites_of(track_id) do
    Repo.all(
      from(i in TrackInvite,
        where: i.track_id == ^track_id,
        order_by: i.created_at,
        select: %{github_id: i.github_id, login: i.login, avatar_url: i.avatar_url}
      )
    )
  end

  @doc "Withdraw a track invitation by the login it was sent to. True when one was there to withdraw."
  @spec remove_invite_by_login(String.t(), String.t()) :: boolean()
  def remove_invite_by_login(track_id, login) do
    lowered = String.downcase(login)

    {n, _} =
      Repo.delete_all(
        from(i in TrackInvite,
          where: i.track_id == ^track_id and fragment("LOWER(?)", i.login) == ^lowered
        )
      )

    n > 0
  end

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
          %Project{archived_at: nil} = project <- [Repo.get(Project, project_id)],
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
          %Track{closed_at: nil} = track <- [Repo.get(Track, track_id)],
          not project_member?(track.project_id, user_id) do
        add_member(track.id, user_id, "invite")
        track
      end

    Repo.delete_all(from(i in TrackInvite, where: i.github_id == ^github_id))
    tracks
  end

  # ── Rows: the link ───────────────────────────────────────────────────

  @doc "Put a track's one link, replacing whatever was there. `ttl_ms` from now."
  @spec put_link(String.t(), String.t(), String.t(), integer()) :: :ok
  def put_link(track_id, token_hash, created_by, ttl_ms) do
    now = DateTime.utc_now()

    %TrackLink{}
    |> TrackLink.changeset(%{
      track_id: track_id,
      token_hash: token_hash,
      created_by: created_by,
      created_at: now,
      expires_at: DateTime.add(now, ttl_ms, :millisecond)
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:token_hash, :created_by, :created_at, :expires_at]},
      conflict_target: :track_id
    )

    :ok
  end

  @doc "When a track's link was made and when it lapses, or nil. Never the hash."
  @spec link_of(String.t()) :: %{created_at: DateTime.t(), expires_at: DateTime.t()} | nil
  def link_of(track_id) do
    Repo.one(
      from(l in TrackLink,
        where: l.track_id == ^track_id,
        select: %{created_at: l.created_at, expires_at: l.expires_at}
      )
    )
  end

  @doc "Delete a track's link. Nobody who came in on it is touched."
  @spec drop_link(String.t()) :: :ok
  def drop_link(track_id) do
    Repo.delete_all(from(l in TrackLink, where: l.track_id == ^track_id))
    :ok
  end

  @doc "The track a link opens, or nil if it is unknown, revoked, expired, or the track closed."
  @spec track_for_link(String.t()) :: Track.t() | nil
  def track_for_link(token_hash) do
    with %TrackLink{} = link <- Repo.get_by(TrackLink, token_hash: token_hash),
         true <- live?(link.expires_at),
         %Track{closed_at: nil} = track <- Repo.get(Track, link.track_id) do
      track
    else
      _ -> nil
    end
  end

  # ── Rows: who else is in a project ───────────────────────────────────

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

  @doc "Take `user_id` off a project: the row, and every preview grant on every open track of it."
  @spec remove_project_member(String.t(), String.t()) :: :ok
  def remove_project_member(project_id, user_id) do
    tracks =
      Repo.all(from(t in Track, where: t.project_id == ^project_id and is_nil(t.closed_at)))

    Enum.each(tracks, &Ravix.Previews.revoke(&1.id, user_id))
    Enum.each(tracks, &Ravix.Previews.revoke_agent(&1.id, user_id))

    Repo.delete_all(
      from(m in ProjectMember, where: m.project_id == ^project_id and m.user_id == ^user_id)
    )

    :ok
  end

  @doc "Whether `user_id` was let into the whole project. The owner is not: ownership is a column."
  @spec project_member?(String.t(), String.t()) :: boolean()
  def project_member?(project_id, user_id) do
    Repo.exists?(
      from(m in ProjectMember, where: m.project_id == ^project_id and m.user_id == ^user_id)
    )
  end

  @doc "Everyone invited to the whole project, oldest first. Excludes the owner."
  @spec project_members_of(String.t()) :: [User.t()]
  def project_members_of(project_id) do
    Repo.all(
      from(m in ProjectMember,
        join: u in assoc(m, :user),
        where: m.project_id == ^project_id,
        order_by: m.created_at,
        select: u
      )
    )
  end

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
  def project_invites_of(project_id) do
    Repo.all(
      from(i in ProjectInvite,
        where: i.project_id == ^project_id,
        order_by: i.created_at,
        select: %{github_id: i.github_id, login: i.login, avatar_url: i.avatar_url}
      )
    )
  end

  @doc "Withdraw a project invitation by the login it was sent to. True when one was there to withdraw."
  @spec remove_project_invite_by_login(String.t(), String.t()) :: boolean()
  def remove_project_invite_by_login(project_id, login) do
    lowered = String.downcase(login)

    {n, _} =
      Repo.delete_all(
        from(i in ProjectInvite,
          where: i.project_id == ^project_id and fragment("LOWER(?)", i.login) == ^lowered
        )
      )

    n > 0
  end

  @doc "Put a project's one link, replacing whatever was there. `ttl_ms` from now."
  @spec put_project_link(String.t(), String.t(), String.t(), integer()) :: :ok
  def put_project_link(project_id, token_hash, created_by, ttl_ms) do
    now = DateTime.utc_now()

    %ProjectLink{}
    |> ProjectLink.changeset(%{
      project_id: project_id,
      token_hash: token_hash,
      created_by: created_by,
      created_at: now,
      expires_at: DateTime.add(now, ttl_ms, :millisecond)
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:token_hash, :created_by, :created_at, :expires_at]},
      conflict_target: :project_id
    )

    :ok
  end

  @doc "When a project's link was made and when it lapses, or nil. Never the hash."
  @spec project_link_of(String.t()) :: %{created_at: DateTime.t(), expires_at: DateTime.t()} | nil
  def project_link_of(project_id) do
    Repo.one(
      from(l in ProjectLink,
        where: l.project_id == ^project_id,
        select: %{created_at: l.created_at, expires_at: l.expires_at}
      )
    )
  end

  @doc "Delete a project's link. Nobody who came in on it is touched."
  @spec drop_project_link(String.t()) :: :ok
  def drop_project_link(project_id) do
    Repo.delete_all(from(l in ProjectLink, where: l.project_id == ^project_id))
    :ok
  end

  @doc "The project a link opens, or nil if it is unknown, revoked, expired or archived."
  @spec project_for_link(String.t()) :: Project.t() | nil
  def project_for_link(token_hash) do
    with %ProjectLink{} = link <- Repo.get_by(ProjectLink, token_hash: token_hash),
         true <- live?(link.expires_at),
         %Project{archived_at: nil} = project <- Repo.get(Project, link.project_id) do
      project
    else
      _ -> nil
    end
  end

  defp live?(expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp track_ids_of(project_id),
    do: from(t in Track, where: t.project_id == ^project_id, select: t.id)

  # ── Rows: what you have not read ─────────────────────────────────────

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
end
