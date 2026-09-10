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

  Every function here takes the signed-in `%Ravix.Accounts.User{}` and goes
  through one of the doors in `Ravix.Accounts.Access` before touching a row.
  There are no exceptions, and that is now something the compiler can show
  rather than something a reader has to check: the rows themselves live in
  `Ravix.People.Store`, which takes ids and asks nobody's permission.

  They shared this module until they did not. `drop_link/2` refused anyone
  but the owner and `drop_link/1` refused nobody, forty lines apart under a
  divider asking the reader to remember which half they were in.
  """

  alias Ravix.Accounts.{Access, User}
  alias Ravix.People.Store
  alias Ravix.Projects.{Project, ProjectLink}
  alias Ravix.Tracks.{Track, TrackLink}

  @typedoc """
  Somebody in a people list, as a page reads it.

  The shape is `Ravix.People.Store`'s, named again here because a page may
  not mention a store -- `Ravix.Credo.Architecture` refuses it, and a
  typespec is a mention.
  """
  @type person :: Store.person()

  @typedoc "How this person comes to be in the list; see `Ravix.People.Store.via/0`."
  @type via :: Store.via()

  @typedoc "A GitHub account the invite box suggests; see `Ravix.People.Store.profile/0`."
  @type profile :: Store.profile()

  @typedoc "The `InviteLink` of `shared/api.ts`. `url` is only ever present at the moment of minting."
  @type invite_link :: %{
          url: String.t() | nil,
          created_at: DateTime.t(),
          expires_at: DateTime.t()
        }

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
  @spec search(User.t(), String.t() | nil) :: [profile()]
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
      |> Enum.map(&Store.present_person/1)
    end
  end

  # ── a track's people ─────────────────────────────────────────────────

  @doc "Who can reach this track (`GET /api/tracks/:id/people`)."
  @spec list(User.t(), String.t()) :: {:ok, [Store.person()]} | {:error, :not_found}
  def list(%User{} = user, track_id) do
    with {:ok, %{track: track, project: project}} <- Access.track_access(user, track_id) do
      {:ok, Store.people_of(track.id, project.user_id, project.id)}
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
  @spec add(User.t(), String.t(), String.t() | nil) ::
          {:ok, [Store.person()]} | {:error, reason()}
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
  The owner removing somebody from a track, or somebody removing themselves
  (`DELETE /api/tracks/:id/people/:login`).

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
    with {:ok, %{track: track, project: project, role: role}} <-
           Access.track_access(user, track_id) do
      wanted = strip_at(login)

      # An invitation that has not been taken up yet is cancelled rather
      # than removed: there is no membership to delete, only a promise to
      # withdraw. Owner-only, because a pending person has no session to ask
      # with.
      if role == :owner and Store.remove_invite_by_login(track.id, wanted) do
        Ravix.Hub.publish(project.id, :people, track_id: track.id)
        {:ok, Store.people_of(track.id, project.user_id, project.id)}
      else
        remove_from_track(user, track, project, role, wanted)
      end
    end
  end

  defp remove_from_track(user, track, project, role, wanted) do
    with {:ok, target} <- find_person(wanted),
         :ok <- may_remove(role, user, target),
         :ok <- refuse_project_member(project, user, target) do
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

  # Somebody here by way of the *project* is not the track dialog's to
  # remove. Silently widening one click into "out of every track on this
  # machine" would be the most surprising thing either dialog could do, so
  # it is named and refused, and the sentence says where the control
  # actually is.
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

  # ── the same three routes, one level up ──────────────────────────────

  @doc "Who can reach every track on this project (`GET /api/projects/:id/people`)."
  @spec list_project(User.t(), String.t()) :: {:ok, [Store.person()]} | {:error, :not_found}
  def list_project(%User{} = user, project_id) do
    with {:ok, %{project: project}} <- Access.project_access(user, project_id) do
      {:ok, Store.project_people_of(project.id, project.user_id)}
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
          {:ok, [Store.person()]} | {:error, reason()}
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
      {:ok, Store.project_people_of(project.id, project.user_id)}
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
          {:ok, [Store.person()] | :left} | {:error, reason()}
  def remove_project(%User{} = user, project_id, login) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id) do
      wanted = strip_at(login)

      # As on a track: an invitation nobody has taken up is withdrawn rather
      # than removed. Owner-only, because a pending person has no session to
      # ask with.
      if role == :owner and Store.remove_project_invite_by_login(project.id, wanted) do
        Ravix.Hub.publish(project.id, :people)
        {:ok, Store.project_people_of(project.id, project.user_id)}
      else
        remove_from_project(user, project, role, wanted)
      end
    end
  end

  defp remove_from_project(user, project, role, wanted) do
    with {:ok, target} <- find_person(wanted),
         :ok <- may_remove(role, user, target) do
      Store.remove_project_member(project.id, target.id)

      # Nothing left to hand back to somebody who just removed their own
      # access. The caller has to leave rather than re-render.
      if target.id == user.id and role != :owner,
        do: {:ok, :left},
        else: {:ok, Store.project_people_of(project.id, project.user_id)}
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

  # ── the other way in: a link ─────────────────────────────────────────

  @doc "Whether a track link is out, never the link itself (`GET /api/tracks/:id/link`). Owner-only."
  @spec link(User.t(), String.t()) :: {:ok, invite_link() | nil} | {:error, reason()}
  def link(%User{} = user, track_id) do
    with {:ok, %{track: track, role: role}} <- Access.track_access(user, track_id),
         :ok <- Access.require_owner(role, "see this track's invite link") do
      # The URL is deliberately absent. Only the hash is stored, so it
      # genuinely cannot be shown again, which is worth being honest about
      # rather than implying it was lost.
      {:ok, describe_link(Store.link_of(track.id))}
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
      Store.put_link(track.id, Ravix.Crypto.sha256(token), user.id, @link_ttl_ms)
      {:ok, minted(Store.link_of(track.id), token)}
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
      Store.drop_link(track.id)
    end
  end

  @doc "Whether a project link is out, never the link itself (`GET /api/projects/:id/link`). Owner-only."
  @spec project_link(User.t(), String.t()) :: {:ok, invite_link() | nil} | {:error, reason()}
  def project_link(%User{} = user, project_id) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         :ok <- Access.require_owner(role, "see this project's invite link") do
      {:ok, describe_link(Store.project_link_of(project.id))}
    end
  end

  @doc "Mint a project link, replacing whatever was out (`POST /api/projects/:id/link`). Owner-only."
  @spec mint_project_link(User.t(), String.t()) :: {:ok, invite_link()} | {:error, reason()}
  def mint_project_link(%User{} = user, project_id) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         :ok <- Access.require_owner(role, "make an invite link for a project") do
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

  @doc "Revoke a project link (`DELETE /api/projects/:id/link`): nobody new gets in on it. Owner-only."
  @spec drop_project_link(User.t(), String.t()) :: :ok | {:error, reason()}
  def drop_project_link(%User{} = user, project_id) do
    with {:ok, %{project: project, role: role}} <- Access.project_access(user, project_id),
         :ok <- Access.require_owner(role, "revoke this project's invite link") do
      Store.drop_project_link(project.id)
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

    case Store.track_for_link(hash) do
      %Track{} = track -> redeem_track(user_id, track)
      nil -> redeem_project(user_id, Store.project_for_link(hash))
    end
  end

  @typedoc "What a link opens, for the page that asks before claiming it."
  @type link_target :: %{
          kind: :project | :track,
          project: String.t(),
          track: String.t() | nil,
          invited_by: String.t() | nil
        }

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

  `invited_by` is whoever minted the link, by login. Worth naming: an invitation
  is a claim about who is asking, and the one piece of it a stranger cannot
  forge is the account that actually holds the project.
  """
  @spec link_target(String.t()) :: {:ok, link_target()} | :error
  def link_target(token) do
    hash = Ravix.Crypto.sha256(token)

    case Store.track_for_link(hash) do
      %Track{} = track -> track_target(track, hash)
      nil -> project_target(Store.project_for_link(hash), hash)
    end
  end

  defp track_target(%Track{} = track, hash) do
    # ownership: the link's hash is the authorization here, and it was just
    # matched against this track's row.
    case Store.live_project(track.project_id) do
      %Project{} = project ->
        {:ok,
         %{
           kind: :track,
           project: project.name,
           track: track.title,
           invited_by: Store.minted_by(TrackLink, :track_id, track.id, hash)
         }}

      _ ->
        :error
    end
  end

  defp project_target(nil, _hash), do: :error

  defp project_target(%Project{} = project, hash) do
    {:ok,
     %{
       kind: :project,
       project: project.name,
       track: nil,
       invited_by: Store.minted_by(ProjectLink, :project_id, project.id, hash)
     }}
  end

  defp redeem_track(user_id, %Track{} = track) do
    # ownership: as `track_target/2` -- holding the link is what admits this
    # caller, and `Store.track_for_link/1` has already matched it.
    case Store.live_project(track.project_id) do
      %Project{} = project ->
        # Somebody already in the whole project needs no row and gets none:
        # a track membership written here would outlive their project
        # membership and quietly leave them one branch after being removed.
        if project.user_id != user_id and not Store.project_member?(project.id, user_id),
          do: Store.add_member(track.id, user_id, "link")

        Ravix.Hub.publish(project.id, :people, track_id: track.id)
        {:ok, "/p/#{project.id}/t/#{track.id}"}

      _ ->
        :error
    end
  end

  defp redeem_project(_user_id, nil), do: :error

  defp redeem_project(user_id, %Project{} = project) do
    if project.user_id != user_id, do: Store.add_project_member(project.id, user_id, "link")
    Ravix.Hub.publish(project.id, :people)
    # The project rather than one of its tracks: this link did not name
    # one, and picking a track for somebody is picking which of several
    # conversations they have walked into.
    {:ok, "/p/#{project.id}"}
  end
end
