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

  alias Ravix.Accounts.{ProjectAccess, TrackAccess, User}
  alias Ravix.People.Store, as: People
  alias Ravix.Projects.Project
  alias Ravix.Projects.Store, as: Projects
  alias Ravix.Repo
  alias Ravix.Tracks.Track

  @typedoc "Owner, or somebody invited to the track or the project in question."
  @type role :: :owner | :member

  @typedoc "Which of the three ways in reaches a project. See `access_of/3`."
  @type access :: :owner | :project | :tracks

  @typedoc """
  Membership a caller has already read, so `access_of/3` need not read it again.

  `:projects` is the set of project ids this person was let into whole;
  `:tracks` is the set of project ids they hold an open track on, or the
  track rows themselves. A key left out is read from the database for the
  one project asked about.
  """
  @type known :: [
          {:projects, MapSet.t(String.t())}
          | {:tracks, MapSet.t(String.t()) | [Track.t()]}
        ]

  @typedoc "What `project_access/2` answers. See `Ravix.Accounts.ProjectAccess`."
  @type project_access :: ProjectAccess.t()

  @typedoc "What `track_access/2` answers. See `Ravix.Accounts.TrackAccess`."
  @type track_access :: TrackAccess.t()

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
        {:ok, %ProjectAccess{project: project, role: :owner}}

      %Project{} = project ->
        if project_member?(project.id, user_id),
          do: {:ok, %ProjectAccess{project: project, role: :member}},
          else: {:error, :not_found}
    end
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
      cond do
        project.user_id == user_id ->
          {:ok, %TrackAccess{track: track, project: project, role: :owner}}

        track.closed_at != nil ->
          {:error, :not_found}

        member?(track.id, user_id) or project_member?(project.id, user_id) ->
          {:ok, %TrackAccess{track: track, project: project, role: :member}}

        true ->
          {:error, :not_found}
      end
    else
      _ -> {:error, :not_found}
    end
  end

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
      on_tracks?(project.id, user_id, known[:tracks]) -> :tracks
      true -> nil
    end
  end

  defp in_project?(project_id, user_id, nil), do: project_member?(project_id, user_id)
  defp in_project?(project_id, _user_id, %MapSet{} = ids), do: MapSet.member?(ids, project_id)

  # ownership: the door itself, as `member?/2` -- this is the third of the
  # three questions `access_of/3` exists to answer, not a read behind one.
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

  # ownership: this is a door, not something behind one. The question "was
  this person named on this track" has no earlier authorization to establish,
  because it *is* the authorization every other caller establishes.
  """
  @spec member?(String.t(), String.t()) :: boolean()
  defdelegate member?(track_id, user_id), to: People

  @doc """
  Whether `user_id` was let into the whole of `project_id`.

  # ownership: as `member?/2` -- the door itself.
  """
  @spec project_member?(String.t(), String.t()) :: boolean()
  defdelegate project_member?(project_id, user_id), to: People

  # A project that exists and has not been archived. Every door starts here:
  # an archived project is gone for everybody, its owner included.
  #
  # ownership: `Ravix.Projects.Store.live_project/1` is that read, and lives
  # there so this module and `Ravix.People` cannot come to differ about what
  # "archived" means.
  defp live_project(project_id), do: Projects.live_project(project_id)

  # ownership: a door again. Whether the track exists at all is the first
  # thing `track_access/2` has to know, before there is anyone to check.
  defp get_track(track_id) when is_binary(track_id), do: Repo.get(Track, track_id)
  defp get_track(_), do: nil
end
